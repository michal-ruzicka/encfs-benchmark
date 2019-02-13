#!/usr/bin/perl

# Benchmark EncFS against plain filesystem

use File::Temp;
use Path::Tiny;
use warnings;

# Create a new empty working directory
sub newWorkingDir {
    my $prefix     = shift;
    my $workingDir = mkdtemp("$prefix/encfs-performance-XXXX")
      || die("Could not create temporary directory");

    return $workingDir;
}

sub cleanup {
    print "cleaning up...";
    my $workingDir = shift;
    system("fusermount -u $workingDir/encfs_plaintext");
    system("rm -Rf $workingDir");
    print "done\n";
}

# Wait for a file to appear
use Time::HiRes qw(usleep);
sub waitForFile
{
	my $file = shift;
	my $timeout;
	$timeout = shift or $timeout = 5;
	for(my $i = $timeout*10; $i > 0; $i--)
	{
		-f $file and return 1;
		usleep(100000); # 0.1 seconds
	}
	print "# timeout waiting for '$file' to appear\n";
	return 0;
}

sub mount_encfs {
    my $workingDir = shift;

    my $c = path("$workingDir/encfs_ciphertext");
    my $p = path("$workingDir/encfs_plaintext");

    $c->mkpath;
    $p->mkpath;

    $c = $c->absolute;
    $p = $p->absolute;

    delete $ENV{"ENCFS6_CONFIG"};
    system("encfs --extpass=\"echo test\" --standard $c $p > /dev/null");
    waitForFile("$c/.encfs6.xml") or die("Control file not created");

    print "# encfs mounted on $p\n";

    return $p;
}

sub mount_plain {

    my $workingDir = shift;

    my $p = "$workingDir/plain";

    mkdir($p);

    print "# plain dir on $p\n";

    return $p;
}

# stopwatch_start($name)
# start the stopwatch for test "$name"
sub stopwatch_start {
    stopwatch(1, shift);
}

# stopwatch_stop(\@results)
# stop the stopwatch, save time into @results
sub stopwatch_stop {
    stopwatch(0, shift);
}

# Returns integer $milliseconds from float $seconds
sub ms {
    my $seconds      = shift;
    my $milliseconds = int( $seconds * 1000 );
    return $milliseconds;
}

# See stopwatch_{start,stop} above
use feature 'state';
use Time::HiRes qw( time );
sub stopwatch {
    state $start_time;
    state $name;
    my $start = shift;

    if($start) {
        $name = shift;
        print("* $name... ");
        $start_time = time();
    } else {
        my $delta = ms(time() - $start_time);
        print("$delta ms\n");
        my $results = shift;
        push( @$results, [ $name, $delta, 'ms' ] );
    }
}

# writeZeroes($filename, $size)
# Write zeroes of size $size to file $filename
sub writeZeroes
{
        my $filename = shift;
        my $size = shift;
        open(my $fh, ">", $filename);
        my $bs = 4096; # 4 KiB
        my $block = "\0" x $bs;
        my $remain;
        for($remain = $size; $remain >= $bs; $remain -= $bs)
        {
                print($fh $block) or BAIL_OUT("Could not write to $filename: $!");
        }
        if($remain > 0)
        {
                $block = "\0" x $remain;
                print($fh $block) or BAIL_OUT("Could not write to $filename: $!");
        }
}

sub benchmark {
    my $dir = shift;
    our $linuxgz;

    my @results = ();

    system("sync");
    stopwatch_start("stream_write");
        writeZeroes( "$dir/zero", 1024 * 1024 * 100 );
        system("sync");
    stopwatch_stop(\@results);
    unlink("$dir/zero");

    system("sync");
    system("cat $linuxgz > /dev/null");
    stopwatch_start("extract");
        system("tar xzf $linuxgz -C $dir");
        system("sync");
    stopwatch_stop(\@results);

    $du = qx(du -sm $dir | cut -f1);
    push( @results, [ 'du', $du, 'MiB' ] );
    printf( "# disk space used: %d MiB\n", $du );

    system("echo 3 > /proc/sys/vm/drop_caches");
    stopwatch_start("rsync");
        system("rsync -an $dir $dir/empty-rsync-target");
    stopwatch_stop(\@results);

    system("echo 3 > /proc/sys/vm/drop_caches");
    system("sync");
    stopwatch_start("rm");
        system("rm -Rf $dir/*");
        system("sync");
    stopwatch_stop(\@results);

    return \@results;
}

sub tabulate {
    my $r;

    $r = shift;
    my @encfs = @{$r};
    $r = shift;
    my @plain;
    if($r) {
        @plain = @{$r};
    }

    print " Test           | EncFS        | plain        | EncFS performance\n";
    print ":---------------|-------------:|-------------:|------------------:\n";

    for ( my $i = 0 ; $i <= $#encfs ; $i++ ) {
        my $test = $encfs[$i][0];
        my $unit = $encfs[$i][2];

        my $en = $encfs[$i][1];
        my $pl = 0;
        my $ratio = 0;

        if( @plain ) {
            $pl = $plain[$i][1];
            $ratio = $pl / $en;
            if ( $unit =~ m!/s! ) {
                $ratio = $en / $pl;
            }
        }

        my $percent = $ratio * 100;

        printf( "%-15s | %6d %-5s | %6d %-5s | %6.2f %%\n",
            $test, $en, $unit, $pl, $unit, $percent );
    }
}

# Download linux-3.0.tar.gz unless it already exists ("-c" flag)
sub dl_linuxgz {
    our $linuxgz = "/var/tmp/linux-3.0.tar.gz";
    if ( -e $linuxgz ) { return; }
    print "downloading linux-3.0.tar.gz (93 MiB)... ";
    system("wget -nv -c https://www.kernel.org/pub/linux/kernel/v3.x/linux-3.0.tar.gz -O $linuxgz");
    print "done\n";
}

sub main {
    if ( $#ARGV < 0 ) {
        print "Usage: test/benchmark.pl DIR1 [DIR2] [...]\n";
        print "\n";
        print "Arguments:\n";
        print "  DIRn ... Working directory. This is where the encrypted files\n";
        print "           are stored. Specifying multiple directories will run\n";
        print "           the benchmark in each.\n";
        print "\n";

        exit(1);
    }

    if ( $> != 0 ) {
        print("This test must be run as root!\n");
        exit(2);
    }

    dl_linuxgz();
    my $workingDir;
    my $mountpoint;
    my $prefix;

    while ( $prefix = shift(@ARGV) ) {
        $workingDir = newWorkingDir($prefix);

        print "# mounting encfs\n";
        $mountpoint = mount_encfs($workingDir);
        my $encfs_results = benchmark($mountpoint);

        print "# preparint plain dir\n";
        $mountpoint = mount_plain($workingDir);
        my $plain_results;
        if($mountpoint) {
            $plain_results = benchmark($mountpoint);
        }

        cleanup($workingDir);

        print "\nResults for $prefix\n";
        print "==============================\n\n";
        tabulate( $encfs_results, $plain_results );
        print "\n";
    }
}

main();
