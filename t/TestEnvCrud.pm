package TestEnv;

use strict;
use warnings;

use Path::Class;
use Sys::Hostname;
use UR;

my $current_repo_path;
my $test_data_path;
INIT { # runs after compilation, right before execution
    $current_repo_path = dir( (caller())[1] )->absolute->parent->parent;
    $test_data_path = $current_repo_path->subdir('t', 'data');

    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
    $ENV{UR_DBI_NO_COMMIT} = 1;

    my $lib = File::Spec->join($current_repo_path, 'lib');
    eval "use lib '$lib';";
    die "FATAL: $@" if $@;

    my $use = <<USE;
    use UR;
USE
    eval $use;
    die "FATAL: $@" if $@;

    printf(STDERR "***** TEST ENV on %s *****\n", Sys::Hostname::hostname);
}

sub current_repo_path { $current_repo_path };
sub test_data_path { $test_data_path };

sub test_data_directory_for_package {
    my ($class, $pkg) = @_;
    die 'No package given to get test data directory' if not $pkg;
    test_data_path()->subdir( join('-', split('::', $pkg)) );
}

class Test::Job {
    is => 'UR::Object',
    id_generator => '-uuid',
    id_by => {
        job_id => { is => 'Number', },
    },
    has => {
        name => { is => 'Text', },
    },
};
sub Test::Job::__display_name__ { $_[0]->name }

class Test::Relationship {
    is  => 'UR::Object',
    id_generator => '-uuid',
    id_by => {
        muppet_id => { is => 'Number', implied_by => 'muppet', },
        related_id => { is => 'Number', implied_by => 'related' },
        name => { is => 'Text', },
    },
    has => {
        muppet => { is => 'Test::Muppet', id_by => 'muppet_id', },
        related => { is => 'Test::Muppet', id_by => 'related_id' },
    },
};

class Test::Muppet {
    is => 'UR::Object',
    id_generator => '-uuid',
    has => {
        name => { is => 'Text', doc => 'Name of the muppet', },
        title => {
            is => 'Text',
            is_optional => 1,
            valid_values => [qw/ mr sir mrs ms miss dr /],
            doc => 'Title',
        },
        job => {
            is => 'Test::Job',
            id_by => 'job_id',
            is_optional => 1,
            doc => 'The muppet\'s job',
        },
        relationships => {
            is => 'Test::Relationship',
            is_many => 1,
            is_optional => 1,
            reverse_as => 'muppet',
            doc => 'This muppet\'s relationships',
        },
        friends => {
            is => 'Test::Muppet',
            is_many => 1,
            is_optional => 1,
            is_mutable => 1,
            via => 'relationships',
            to => 'related',
            where => [ 'name' => 'friend' ],
            doc => 'Friends of this muppet',
        },
       best_friend => {
           is => 'Test::Muppet',
           is_optional => 1,
           is_mutable => 1,
           is_many => 0,
           via => 'relationships',
           to => 'related',
           where => [ name => 'best friend' ],
           doc => 'Best friend of this muppet',
       },
    },
};
sub Test::Muppet::__display_name__ { $_[0]->name }

1;
