package Dist::Zilla;
use Moose;
use Moose::Autobox;
use MooseX::Types::Path::Class qw(Dir File);
use Moose::Util::TypeConstraints;

our $VERSION = '0.001';

use File::Find::Rule;
use Path::Class ();
use Software::License;

use Dist::Zilla::Config;

use Dist::Zilla::File::OnDisk;
use Dist::Zilla::Role::Plugin;

has name => (
  is   => 'ro',
  isa  => 'Str',
  required => 1,
);

# XXX: *clearly* this needs to be really much smarter -- rjbs, 2008-06-01
has version => (
  is   => 'rw',
  isa  => 'Str',
  required => 1,
);

has copyright_holder => (
  is   => 'ro',
  isa  => 'Str',
  required => 1,
);

has copyright_year => (
  is   => 'ro',
  isa  => 'Int',
  default => (localtime)[5] + 1900,
);

has license => (
  is   => 'ro',
  isa  => 'Software::License',
);

has authors => (
  is   => 'ro',
  isa  => 'ArrayRef[Str]',
  required => 1,
);

has build_root => (
  is   => 'ro',
  isa  => Dir,
  lazy    => 1,
  default => sub { Path::Class::dir('build') },
);

sub from_dir {
  my ($class, $root) = @_;

  $root = Path::Class::dir($root) unless ref $root;

  my $config_file = $root->file('dist.ini');
  my $config = Dist::Zilla::Config->read_file($config_file);

  my $plugins = delete $config->{plugins};

  my $license_name  = delete $config->{license};
  my $license_class = "Software::License::$license_name";

  eval "require $license_class; 1" or die;

  my $self = $class->new($config->merge({ root => $root }));

  my $license = $license_class->new({
    holder => $self->copyright_holder,
    year   => $self->copyright_year,
  });

  # XXX: fix this -- rjbs, 2008-06-01
  $self->{license} = $license;

  for my $plugin (@$plugins) {
    my ($plugin_class, $arg) = @$plugin;
    $self->plugins->push(
      $plugin_class->new( $arg->merge({ zilla => $self }) )
    );
  }

  return $self;
}

has plugins => (
  is   => 'ro',
  isa  => 'ArrayRef[Dist::Zilla::Role::Plugin]',
  default => sub { [ ] },
);

has files => (
  is   => 'ro',
  isa  => 'ArrayRef',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    my $root = $self->root;
    my @files = File::Find::Rule
              ->not( File::Find::Rule->name(qr/^\./) )
              ->file
              ->in($root);

    return \@files;
  },
);

sub plugins_with {
  my ($self, $role) = @_;

  $role =~ s/^-/Dist::Zilla::Role::/;
  my $plugins = $self->plugins->grep(sub { $_->does($role) });

  return $plugins;
}

has root => (
  is   => 'ro',
  isa  => Dir,
  coerce   => 1,
  required => 1,
);

sub manifest {
  my ($self) = @_;
  
  my $files = [ $self->files->flatten ];

  $_->prune_files($files) for $self->plugins_with(-FilePruner)->flatten;

  return $files;
}

sub prereq {
  my ($self) = @_;

  # XXX: This needs to always include the highest version. -- rjbs, 2008-06-01
  my $prereq = {};
  $prereq = $prereq->merge( $_->prereq )
    for $self->plugins_with(-FixedPrereqs)->flatten;

  return $prereq;
}

sub build_dist {
  my ($self, $root) = @_;

  my $build_root = Path::Class::dir($root);
  $build_root->mkpath unless -d $build_root;

  my $dist_root = $self->root;
  my $manifest  = $self->manifest;

  my $files = $manifest->map(sub {
    Dist::Zilla::File::OnDisk->new({ name => $_ });
  });

  for ($self->plugins_with(-FileWriter)->flatten) {
    my $new_files = $_->write_files({
      build_root => $build_root,
      dist       => $self,
      manifest   => $manifest,
    });

    $files->push($new_files->flatten);
  }

  for my $file ($files->flatten) {
    $_->munge_file($file) for $self->plugins_with(-FileMunger)->flatten;

    my $_file = Path::Class::file($file->name);

    my $to_dir = $build_root->subdir( $_file->dir );
    my $to = $to_dir->file( $_file->basename );
    $to_dir->mkpath unless -e $to_dir;
    die "not a directory: $to_dir" unless -d $to_dir;
  
    Carp::croak("attempted to write $to multiple times") if -e $to;

    open my $out_fh, '>', "$to" or die "couldn't open $to to write: $!";
    print { $out_fh } $file->content;
    close $out_fh or die "error closing $to: $!";
  }

  for ($self->plugins_with(-AfterBuild)->flatten) {
    $_->after_build({
      build_root => $build_root,
      dist       => $self,
      files      => $files,
    });
  }
}

# XXX: yeah, uh, do something more awesome -- rjbs, 2008-06-01
sub log {
  my ($self, $msg) = @_;
  print "$msg\n";
}

no Moose;
1;