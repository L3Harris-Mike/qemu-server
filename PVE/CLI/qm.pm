package PVE::CLI::qm;

use strict;
use warnings;

# Note: disable '+' prefix for Getopt::Long (for resize command)
use Getopt::Long qw(:config no_getopt_compat);

use Fcntl ':flock';
use File::Path;
use IO::Socket::UNIX;
use IO::Select;

use PVE::Tools qw(extract_param);
use PVE::Cluster;
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::RPCEnvironment;
use PVE::QemuServer;
use PVE::API2::Qemu;
use PVE::JSONSchema qw(get_standard_option);
use Term::ReadLine;

use PVE::CLIHandler;

use base qw(PVE::CLIHandler);

my $upid_exit = sub {
    my $upid = shift;
    my $status = PVE::Tools::upid_read_status($upid);
    exit($status eq 'OK' ? 0 : -1);
};

my $nodename = PVE::INotify::nodename();

sub run_vnc_proxy {
    my ($path) = @_;

    my $c;
    while ( ++$c < 10 && !-e $path ) { sleep(1); }

    my $s = IO::Socket::UNIX->new(Peer => $path, Timeout => 120);

    die "unable to connect to socket '$path' - $!" if !$s;

    my $select = new IO::Select;

    $select->add(\*STDIN);
    $select->add($s);

    my $timeout = 60*15; # 15 minutes

    my @handles;
    while ($select->count &&
	   scalar(@handles = $select->can_read ($timeout))) {
	foreach my $h (@handles) {
	    my $buf;
	    my $n = $h->sysread($buf, 4096);

	    if ($h == \*STDIN) {
		if ($n) {
		    syswrite($s, $buf);
		} else {
		    exit(0);
		}
	    } elsif ($h == $s) {
		if ($n) {
		    syswrite(\*STDOUT, $buf);
		} else {
		    exit(0);
		}
	    }
	}
    }
    exit(0);
}

__PACKAGE__->register_method ({
    name => 'showcmd',
    path => 'showcmd',
    method => 'GET',
    description => "Show command line which is used to start the VM (debug info).",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid }),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $storecfg = PVE::Storage::config();
	print PVE::QemuServer::vm_commandline($storecfg, $param->{vmid}) . "\n";

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'status',
    path => 'status',
    method => 'GET',
    description => "Show VM status.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid }),
	    verbose => {
		description => "Verbose output format",
		type => 'boolean',
		optional => 1,
	    }
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::QemuConfig->load_config ($param->{vmid});

	my $vmstatus = PVE::QemuServer::vmstatus($param->{vmid}, 1);
	my $stat = $vmstatus->{$param->{vmid}};
	if ($param->{verbose}) {
	    foreach my $k (sort (keys %$stat)) {
		next if $k eq 'cpu' || $k eq 'relcpu'; # always 0
		my $v = $stat->{$k};
		next if !defined($v);
		print "$k: $v\n";
	    }
	} else {
	    my $status = $stat->{qmpstatus} || 'unknown';
	    print "status: $status\n";
	}

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'vncproxy',
    path => 'vncproxy',
    method => 'PUT',
    description => "Proxy VM VNC traffic to stdin/stdout",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid_running }),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};
	my $vnc_socket = PVE::QemuServer::vnc_socket($vmid);

	if (my $ticket = $ENV{LC_PVE_TICKET}) {  # NOTE: ssh on debian only pass LC_* variables
	    PVE::QemuServer::vm_mon_cmd($vmid, "change", device => 'vnc', target => "unix:$vnc_socket,password");
	    PVE::QemuServer::vm_mon_cmd($vmid, "set_password", protocol => 'vnc', password => $ticket);
	    PVE::QemuServer::vm_mon_cmd($vmid, "expire_password", protocol => 'vnc', time => "+30");
	} else {
	    PVE::QemuServer::vm_mon_cmd($vmid, "change", device => 'vnc', target => "unix:$vnc_socket,x509,password");
	}

	run_vnc_proxy($vnc_socket);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'unlock',
    path => 'unlock',
    method => 'PUT',
    description => "Unlock the VM.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid }),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};

	PVE::QemuConfig->lock_config ($vmid, sub {
	    my $conf = PVE::QemuConfig->load_config($vmid);
	    delete $conf->{lock};
	    delete $conf->{pending}->{lock} if $conf->{pending}; # just to be sure
	    PVE::QemuConfig->write_config($vmid, $conf);
	});

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'mtunnel',
    path => 'mtunnel',
    method => 'POST',
    description => "Used by qmigrate - do not use manually.",
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	if (!PVE::Cluster::check_cfs_quorum(1)) {
	    print "no quorum\n";
	    return undef;
	}

	print "tunnel online\n";
	*STDOUT->flush();

	while (my $line = <>) {
	    chomp $line;
	    last if $line =~ m/^quit$/;
	}

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'wait',
    path => 'wait',
    method => 'GET',
    description => "Wait until the VM is stopped.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid_running }),
	    timeout => {
		description => "Timeout in seconds. Default is to wait forever.",
		type => 'integer',
		minimum => 1,
		optional => 1,
	    }
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};
	my $timeout = $param->{timeout};

	my $pid = PVE::QemuServer::check_running ($vmid);
	return if !$pid;

	print "waiting until VM $vmid stopps (PID $pid)\n";

	my $count = 0;
	while ((!$timeout || ($count < $timeout)) && PVE::QemuServer::check_running ($vmid)) {
	    $count++;
	    sleep 1;
	}

	die "wait failed - got timeout\n" if PVE::QemuServer::check_running ($vmid);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'monitor',
    path => 'monitor',
    method => 'POST',
    description => "Enter Qemu Monitor interface.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid_running }),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};

	my $conf = PVE::QemuConfig->load_config ($vmid); # check if VM exists

	print "Entering Qemu Monitor for VM $vmid - type 'help' for help\n";

	my $term = new Term::ReadLine ('qm');

	my $input;
	while (defined ($input = $term->readline('qm> '))) {
	    chomp $input;

	    next if $input =~ m/^\s*$/;

	    last if $input =~ m/^\s*q(uit)?\s*$/;

	    eval {
		print PVE::QemuServer::vm_human_monitor_command ($vmid, $input);
	    };
	    print "ERROR: $@" if $@;
	}

	return undef;

    }});

__PACKAGE__->register_method ({
    name => 'rescan',
    path => 'rescan',
    method => 'POST',
    description => "Rescan all storages and update disk sizes and unused disk images.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', {
		optional => 1,
		completion => \&PVE::QemuServer::complete_vmid,
	    }),
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	PVE::QemuServer::rescan($param->{vmid});

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'terminal',
    path => 'terminal',
    method => 'POST',
    description => "Open a terminal using a serial device (The VM need to have a serial device configured, for example 'serial0: socket')",
    parameters => {
	additionalProperties => 0,
	properties => {
	    vmid => get_standard_option('pve-vmid', { completion => \&PVE::QemuServer::complete_vmid_running }),
	    iface => {
		description => "Select the serial device. By default we simply use the first suitable device.",
		type => 'string',
		optional => 1,
		enum => [qw(serial0 serial1 serial2 serial3)],
	    }
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};

	my $conf = PVE::QemuConfig->load_config ($vmid); # check if VM exists

	my $iface = $param->{iface};

	if ($iface) {
	    die "serial interface '$iface' is not configured\n" if !$conf->{$iface};
	    die "wrong serial type on interface '$iface'\n" if $conf->{$iface} ne 'socket';
	} else {
	    foreach my $opt (qw(serial0 serial1 serial2 serial3)) {
		if ($conf->{$opt} && ($conf->{$opt} eq 'socket')) {
		    $iface = $opt;
		    last;
		}
	    }
	    die "unable to find a serial interface\n" if !$iface;
	}

	die "VM $vmid not running\n" if !PVE::QemuServer::check_running($vmid);

	my $socket = "/var/run/qemu-server/${vmid}.$iface";

	my $cmd = "socat UNIX-CONNECT:$socket STDIO,raw,echo=0,escape=0x0f";

	print "starting serial terminal on interface $iface (press control-O to exit)\n";

	system($cmd);

	return undef;
    }});

our $cmddef = {
    list => [ "PVE::API2::Qemu", 'vmlist', [],
	     { node => $nodename }, sub {
		 my $vmlist = shift;

		 exit 0 if (!scalar(@$vmlist));

		 printf "%10s %-20s %-10s %-10s %12s %-10s\n",
		 qw(VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID);

		 foreach my $rec (sort { $a->{vmid} <=> $b->{vmid} } @$vmlist) {
		     printf "%10s %-20s %-10s %-10s %12.2f %-10s\n", $rec->{vmid}, $rec->{name},
		     $rec->{qmpstatus} || $rec->{status},
		     ($rec->{maxmem} || 0)/(1024*1024),
		     ($rec->{maxdisk} || 0)/(1024*1024*1024),
		     $rec->{pid}||0;
		 }


	      } ],

    create => [ "PVE::API2::Qemu", 'create_vm', ['vmid'], { node => $nodename }, $upid_exit ],

    destroy => [ "PVE::API2::Qemu", 'destroy_vm', ['vmid'], { node => $nodename }, $upid_exit ],

    clone => [ "PVE::API2::Qemu", 'clone_vm', ['vmid', 'newid'], { node => $nodename }, $upid_exit ],

    migrate => [ "PVE::API2::Qemu", 'migrate_vm', ['vmid', 'target'], { node => $nodename }, $upid_exit ],

    set => [ "PVE::API2::Qemu", 'update_vm', ['vmid'], { node => $nodename } ],

    resize => [ "PVE::API2::Qemu", 'resize_vm', ['vmid', 'disk', 'size'], { node => $nodename } ],

    move_disk => [ "PVE::API2::Qemu", 'move_vm_disk', ['vmid', 'disk', 'storage'], { node => $nodename }, $upid_exit ],

    unlink => [ "PVE::API2::Qemu", 'unlink', ['vmid'], { node => $nodename } ],

    config => [ "PVE::API2::Qemu", 'vm_config', ['vmid'],
		{ node => $nodename }, sub {
		    my $config = shift;
		    foreach my $k (sort (keys %$config)) {
			next if $k eq 'digest';
			my $v = $config->{$k};
			if ($k eq 'description') {
			    $v = PVE::Tools::encode_text($v);
			}
			print "$k: $v\n";
		    }
		}],

    pending => [ "PVE::API2::Qemu", 'vm_pending', ['vmid'],
		{ node => $nodename }, sub {
		    my $data = shift;
		    foreach my $item (sort { $a->{key} cmp $b->{key}} @$data) {
			my $k = $item->{key};
			next if $k eq 'digest';
			my $v = $item->{value};
			my $p = $item->{pending};
			if ($k eq 'description') {
			    $v = PVE::Tools::encode_text($v) if defined($v);
			    $p = PVE::Tools::encode_text($p) if defined($p);
			}
			if (defined($v)) {
			    if ($item->{delete}) {
				print "del $k: $v\n";
			    } elsif (defined($p)) {
				print "cur $k: $v\n";
				print "new $k: $p\n";
			    } else {
				print "cur $k: $v\n";
			    }
			} elsif (defined($p)) {
			    print "new $k: $p\n";
			}
		    }
		}],

    showcmd => [ __PACKAGE__, 'showcmd', ['vmid']],

    status => [ __PACKAGE__, 'status', ['vmid']],

    snapshot => [ "PVE::API2::Qemu", 'snapshot', ['vmid', 'snapname'], { node => $nodename } , $upid_exit ],

    delsnapshot => [ "PVE::API2::Qemu", 'delsnapshot', ['vmid', 'snapname'], { node => $nodename } , $upid_exit ],

    rollback => [ "PVE::API2::Qemu", 'rollback', ['vmid', 'snapname'], { node => $nodename } , $upid_exit ],

    template => [ "PVE::API2::Qemu", 'template', ['vmid'], { node => $nodename }],

    start => [ "PVE::API2::Qemu", 'vm_start', ['vmid'], { node => $nodename } , $upid_exit ],

    stop => [ "PVE::API2::Qemu", 'vm_stop', ['vmid'], { node => $nodename }, $upid_exit ],

    reset => [ "PVE::API2::Qemu", 'vm_reset', ['vmid'], { node => $nodename }, $upid_exit ],

    shutdown => [ "PVE::API2::Qemu", 'vm_shutdown', ['vmid'], { node => $nodename }, $upid_exit ],

    suspend => [ "PVE::API2::Qemu", 'vm_suspend', ['vmid'], { node => $nodename }, $upid_exit ],

    resume => [ "PVE::API2::Qemu", 'vm_resume', ['vmid'], { node => $nodename }, $upid_exit ],

    sendkey => [ "PVE::API2::Qemu", 'vm_sendkey', ['vmid', 'key'], { node => $nodename } ],

    vncproxy => [ __PACKAGE__, 'vncproxy', ['vmid']],

    wait => [ __PACKAGE__, 'wait', ['vmid']],

    unlock => [ __PACKAGE__, 'unlock', ['vmid']],

    rescan  => [ __PACKAGE__, 'rescan', []],

    monitor  => [ __PACKAGE__, 'monitor', ['vmid']],

    mtunnel => [ __PACKAGE__, 'mtunnel', []],

    terminal => [ __PACKAGE__, 'terminal', ['vmid']],
};

1;
