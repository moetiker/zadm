package Zadm::Zones;
use Mojo::Base -base;

use Mojo::File;
use Mojo::Log;
use Mojo::Exception;
use Mojo::Promise;
use Mojo::IOLoop::Subprocess;
use FindBin;
use File::Spec;
use Term::ANSIColor qw(colored);
use Zadm::Utils;
use Zadm::Image;
use Zadm::Zone;

# constants
my %ZMAP = (
    zoneid    => 0,
    zonename  => 1,
    state     => 2,
    zonepath  => 3,
    uuid      => 4,
    brand     => 5,
    'ip-type' => 6,
    debugid   => 7,
);

my $DATADIR = "$FindBin::RealBin/../var"; # DATADIR

my $MODPREFIX = 'Zadm::Zone';

# private static methods
my $statecol = sub {
    my $state = shift;

    for ($state) {
        /^running$/                   && return colored($state, 'green');
        /^(?:configured|incomplete)$/ && return colored($state, 'red');
    }

    return colored($state, 'ansi208');
};

# private methods
my $list = sub {
    my $self = shift;

    my $zones = $self->utils->pipe('zoneadm', [ qw(list -cp) ]);

    my %zoneList;
    while (my $zone = <$zones>) {
        chomp $zone;
        my $zoneCfg = { map { $_ => (split /:/, $zone)[$ZMAP{$_}] } keys %ZMAP };
        # ignore GZ
        next if $zoneCfg->{zonename} eq 'global';

        $zoneList{$zoneCfg->{zonename}} = $zoneCfg;
    }

    return \%zoneList;
};


# attributes
has loglvl  => 'warn'; # override to 'debug' for development
has log     => sub { Mojo::Log->new(level => shift->loglvl) };
has utils   => sub { Zadm::Utils->new(log => shift->log) };
has image   => sub { my $self = shift; Zadm::Image->new(log => $self->log, datadir => $self->datadir) };
has datadir => $DATADIR;
has brands  => sub {
    return [
        map {
            Mojo::File->new($_)->slurp =~ /<brand\s+name="([^"]+)"/
        } glob '/usr/lib/brand/*/config.xml'
    ];
};
has brandmap    => sub { my $self = shift; $self->utils->genmap($self->brands) };
has brandExists => sub { exists shift->brandmap->{shift // ''} };
has list        => sub { shift->$list };

has zoneName => sub {
    my $self = shift;

    my $zonename = $self->utils->pipe('zonename');
    chomp (my $zone = <$zonename>);

    return $zone;
};

has isGZ => sub { shift->zoneName eq 'global' };

has modmap => sub {
    my $self = shift;

    # base is the default module
    my %modmap = map { $_ => $MODPREFIX . '::base' } @{$self->brands};

    for my $path (@INC) {
        my @mDirs = split /::|\//, $MODPREFIX;
        my $fPath = File::Spec->catdir($path, @mDirs, '*.pm');
        for my $file (sort glob($fPath)) {
            my ($volume, $modulePath, $modName) = File::Spec->splitpath($file);
            $modName =~ s/\.pm$//;
            next if $modName eq 'base';

            $modmap{lc $modName} = $MODPREFIX . "::$modName" if exists $modmap{lc $modName};
        }
    }

    return \%modmap;
};

# public methods
sub exists {
    return exists shift->list->{shift // ''};
}

sub refresh {
    my $self = shift;

    $self->list($self->$list);
}

sub dump {
    my $self = shift;
    my $opts = shift;

    my $format = "%-18s%-11s%-9s%4s\n";
    my @header = qw(NAME STATUS BRAND RAM);

    my $list  = $self->list;
    # we want the running ones on top and it happens we can just reverse-sort the state
    my @zones = sort { $list->{$b}->{state} cmp $list->{$a}->{state} || $a cmp $b } keys %$list;

    my $ram;
    # TODO: for now we just query 'RAM'. Once we query more attributes we should change
    # the zone interface to extraStats which returns a structure
    Mojo::Promise->all(
        map {
            my $name = $_;
            Mojo::IOLoop::Subprocess->new->run_p(sub { return $self->zone($name)->ram })
        } @zones
    )->then(sub { $ram->{$zones[$_]} = $_[$_]->[0] for (0 .. $#zones) }
    )->wait;

    printf $format, @header;
    printf $format, $_,
        # TODO: printf string length breaks with coloured strings
        $statecol->($list->{$_}->{state}) . (' ' x (11 - length (substr ($list->{$_}->{state}, 0, 10)))),
        $list->{$_}->{brand},
        $ram->{$_},
        for @zones;
}

sub zone {
    my $self  = shift;
    my $zName = shift;
    my %opts  = @_;

    my $create = delete $opts{create};

    Mojo::Exception->throw("ERROR: zone '$zName' already exists. use 'edit' to change properties\n")
        if $create && $self->exists($zName);

    Mojo::Exception->throw("ERROR: zone '$zName' does not exist. use 'create' to create a zone\n")
        if !$create && !$self->exists($zName);

    return Zadm::Zone->new(
        zones => $self,
        log   => $self->log,
        utils => $self->utils,
        image => $self->image,
        name  => $zName,
        %opts,
    );
}

sub config {
    my $self  = shift;
    my $zName = shift;

    # if we want the config for a particular zone, go ahead
    return $self->zone($zName)->config if $zName;

    my $config;
    Mojo::Promise->all(
        map {
            my $name = $_;
            Mojo::IOLoop::Subprocess->new->run_p(sub { return $self->zone($name)->config })
        } keys %{$self->list}
    )->then(sub { $config->{$_->[0]->{zonename}} = $_->[0] for @_ }
    )->wait;

    return $config;
}

1;

__END__

=head1 COPYRIGHT

Copyright 2020 OmniOS Community Edition (OmniOSce) Association.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.
This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.
You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Dominik Hassler E<lt>hadfl@omniosce.orgE<gt>>

=head1 HISTORY

2020-04-12 had Initial Version

=cut
