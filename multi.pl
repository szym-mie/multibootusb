use strict;
use warnings;
use sigtrap qw(die normal-signals);

my $EFIMNT = "/tmp/efimnt";
my $DATAMNT = "/tmp/datamnt";
my $REPODIR = "/tmp/repo";
my $LSFILE = ".ls";
my $BOOTDIR = "$DATAMNT/boot";
my $ISOSDIR = "$BOOTDIR/isos";
my $MBUSBDIR = "mbusb.d";
my $GRUBCFG = "grub.cfg";
my $ZERODEV = "/dev/zero";
my $CHECKFILE = ".checkpoint";

my $ftp;
my $ftpuser;
my $dev;
my $askflag = 1;
my $cleanflag = 0;
sub parse_args {
	while (my $arg = shift @ARGV) {
		if ($arg eq "-f") { $ftp = shift @ARGV; } 
		elsif ($arg eq "-u") { $ftpuser = shift @ARGV; } 
		elsif ($arg eq "-k") { $askflag = 0; }
		elsif ($arg eq "-C") { $cleanflag = 1; }
		elsif ($arg eq "-h") { usage(); } 
		elsif ($arg =~ /-.*/) { die "Invalid argument $arg"; }
		else { $dev = $arg; }
	}
	die "Device was not provided" unless (length $dev);
}

sub usage {
	print <<~"END";
$0 [-h] [-k] [-C] [-f FTP] [-u FTPUSER] DEVICE
Flags:
  -h            Displays this message.
  -k            Don't ask questions when there is only one possible ISO choice. 
  	        Turned off when there is no more space left on the device.
  -C            Clean the disk and don't use checkpoints.
  -f            After the disk is prepared, download ISOs from this FTP path.
                Examples: 'ftp://10.0.0.1/isos', 'ftp://iso.net/pub/iso/'.
                The script will attempt to match files on the remote, using the
                the paths sourced from the configuration files in the 'mbusb.d'
                directory. The script looks for the '# +++FTP' marker in the
                file, and if found, tries to match '/path/to/the/iso.iso' at 
		the following line.
  -u            FTP username. Otherwise the default 'curl' login will be used.
END
	exit 1;              
}

sub normalize {
	$dev =~ s/\/$//;
	$ftp .= "/" if (length $ftp && $ftp !~ /\/$/);
	print "DEV: $dev\nFTP: $ftp\n";
}

parse_args();
normalize();

sub part {
	my ($suffix) = @_;
	$suffix = $suffix || "";
	return "$dev$suffix";
}

sub try_resume {
	open(my $fp,"<",$CHECKFILE); 
	my $step = <$fp> unless (eof($fp));
	my $name = <$fp> unless (eof($fp));
	return ($step || 0,$name || "");
}

sub checkpoint {
	my ($step,$name) = @_;
	open(my $fp,">",$CHECKFILE) or die "Cannot open the $CHECKFILE";
	print {$fp} "$step\n$name";
}

sub fdisk {
	my ($action,$fdev) = @_;
	print "FDISK $action $fdev... ";
	my $err = `make DEV=$fdev $action -f fdisk.mk 2>&1`;
	$? and die "failed with $?\n$err";
	print "OK\n";
}

sub dd {
	my ($inf,$outf,$cnt) = @_;
	print "Clean $outf... ";
	`dd if=$inf bs=1M of=$outf count=$cnt 2>&1`;
	print "OK\n";
}

sub mount {
	my ($fdev,$fnode) = @_;
	print "Mount $fdev... ";
	`mount $fdev $fnode 2>&1`;
	$? and die "failed with $?";
	print "OK\n";
}

sub umount {
	my ($fdev) = @_;
	`umount -f $fdev 2>&1`;
}

sub mkfs {
	my ($type,$fdev) = @_;
	umount($fdev);
	print "MKFS $fdev ($type)... ";
	my $err = `mkfs.$type $fdev 2>&1`;
	$? and die "failed with $?\n$err";
	print "OK\n";
}

sub cp {
	my ($flags,$src,$dst) = @_;
	$flags = "-$flags" if (length $flags);
	print "Copy $src -> $dst... ";
	`cp $flags $src $dst 2>&1`;
	$? and die "failed with $?";
	print "OK\n";
}

sub df {
	my ($fdev) = @_;
	my ($blocks) = `df $fdev` =~ /$fdev\s+([0-9]+)/;
	return int($blocks/1024);
}

sub grub_install {
	my ($mode,$fdev,$bootdir) = @_;
	print "GRUB install $fdev ($mode)... ";
	my $target;
	my $boot = "--boot-directory=$bootdir";
	my $flags;
	if ($mode =~ /bios/) { 
		$target = "--target=i386-pc"; 
		$flags = "--force --recheck";
	}
	if ($mode =~ /efi/) {
		$target = "--target=x86_64-efi"; 
		$flags = "--removable --recheck";
		$fdev = "--efi-directory=$fdev";
	}
	`grub-install $flags $target $boot $fdev 2>&1`;
	$? and die "failed with $?";
	print "OK\n";
}

sub find_pppftp {
	my ($file) = @_;
	open(my $fp,"<",$file) or die "Cannot open file $file";
	my $ftpfound = 0;
	while (my $line = readline($fp)) {
		if ($ftpfound) {
			my ($url) = $line =~ /\/([A-Za-z0-9._*]+)/;
			return $url || "";
		}
		$ftpfound = 1 if ($line =~ /\+\+\+FTP/);
	}
	return "";
}

sub scan_pppftp {
	my ($dir) = @_;
	opendir(my $dp,$dir) or die "Cannot open dir $dir";
	my @urls;
	while (my $f = readdir($dp)) {
		my $path = "$dir/$f";
		if (-f $path) {
			my $pppftp = find_pppftp($path);
			push(@urls,$pppftp) if ($pppftp);
		}
	}
	return @urls;
}

sub scan_urls {
	my ($dir) = @_;
	opendir(my $dp,$dir) or die "cannot open dir $dir";
	my @urls;
	while (my $f = readdir($dp)) {
		my $path = "$dir/$f";
		if ($f eq ".") { next; }
		if ($f eq "..") { next; }
		if (-d $path) { @urls = (@urls,scan_pppftp($path)); }
	}
	return @urls;
}

sub curl {
	my ($user,$baseurl,$basedir,@files,$wrout) = @_;
	my $args = "";
	$args .= "-u $user " if (length $user); 
	$args .= "-w \"$wrout\" " if (length $wrout);
	foreach my $f (@files) {
		$args .= "-o $basedir$f $baseurl$f ";
	}
	`curl $args`;
	$? and die "failed with $?";
}

sub lsftp {
	my @urls = ("");
	print "FTP list $ftp... ";
	curl($ftpuser,$ftp,$LSFILE,@urls);
	open(my $fp,"<",$LSFILE) or die "cannot open $LSFILE";
	my @files;
	readline($fp); # skip first line "total ..."
	while (my $line = readline($fp)) {
		my ($size,$file) = $line =~ /(\S+)\s+(?:\S+\s+){3}(\S+)$/;
		$file =~ s/\n//g;
		my $mb = int($size/1024/1024);
		my @entry = ($file,$mb);
		push(@files,\@entry);
	}
	print "OK\n";
	return @files;
}

sub getftp {
	my ($basedir,@files) = @_;
	print "FTP mget $ftp... ";
	curl($ftpuser,$ftp,$basedir,@files);
	print "OK\n";
}

sub globp { 
	my ($pat) = @_; 
	$pat = $pat || "";
	my %patmap = ('*'=>'.*','?'=>'.','['=>'[',']'=>']'); 
	$pat =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
	return '^'.$pat.'$';
}

sub prompt {
	my ($msg,$spec,$onempty) = @_;
	while (1) {
		print "$msg [$spec] ";
		my $line = <STDIN>;
		my isempty = defined($onempty) && $line eq "\n";
		if ($spec =~ /^\d/i) {
			return $empty if ($isempty);
			my ($input) = $line =~ /^(\d+)\n$/i;
			if (defined($input)) {
				return int($input);
			} else {
				print "Not a number\n";
			}
		} elsif ($spec eq "y/n") {
			return $empty if ($isempty);
			my ($input) = $line =~ /^([yn])\n$/i;
			if (defined($input)) {
				return $input =~ /y/i;
			} else {
				print "Respond y/n\n";
			}
		} else {
			warn "Bad prompt() spec";
			return 0;
		}
	}
}

my $step = 0;
my ($done_step,$done_info) = try_resume();
$done_step = 0 if ($cleanflag);
# Start
print "ALL DATA ON $dev WILL BE ERASED!\n";
exit 0 unless (prompt("Do you want to continue? ","y/n","n"));
if ($done_step > 0) {
	print "Found a checkpoint after $done_info.\n";
	$done_step = 0 unless (prompt("Resume?","y/n","y"));
}

if (++$step > $done_step) {
	# Run fdisk on the device
	fdisk("clean",part()) if ($cleanflag);
	fdisk("init",part());
	checkpoint($step,"the disk was partitioned");
}

if (++$step > $done_step) {
	# Clean filesystems
	dd($ZERODEV,part(1),1);
	# Create filesystems
	mkfs("vfat",part(2));
	mkfs("vfat",part(3));
	checkpoint($step,"the filesystems were created");
}

# Create mountpoints
mkdir $EFIMNT;
mkdir $DATAMNT;
mkdir $REPODIR;
# Mount the filesystem
mount(part(2),$EFIMNT);
mount(part(3),$DATAMNT);

if (++$step > $done_step) {
	# Install GRUB for EFI
	grub_install("efi",$EFIMNT,$BOOTDIR);
	# Install GRUB for BIOS
	grub_install("bios",part(),$BOOTDIR);
	# Install fallback GRUB
	grub_install("bios",part(3),$BOOTDIR);
	checkpoint($step,"the GRUB bootloader was installed");
}

if (++$step > $done_step) {
	# Setup the ISO directory
	mkdir $ISOSDIR;
	cp("R",$MBUSBDIR,"$BOOTDIR/grub/");
	cp("",$GRUBCFG,"$BOOTDIR/grub/");
	checkpoint($step,"the boot files were copied");
}

# Scan for URLs in mbusb.d
my @urls = scan_urls($MBUSBDIR);
print "Found configs for:\n";
foreach my $url (@urls) {
	print ") $url\n";
}

if (length $ftp && prompt("Attempt to download the ISO files?","y/n")) {
	print "Searching for the ISO files...\n";
	my @all = lsftp();
	my @files;
	my $availmb = df(part(3));
	while (1) {
		my @selected;
		foreach my $url (@urls) {
			my $sel;
			my $pat = globp($url);
			my @found = grep { $_->[0] =~ /$pat/ } @all;
			if (@found == 0) {
				print "No results for '$url'\n";
			} elsif (@found > 1 || $askflag) {
				my $i = 0;
				printf "%4d) none\n",$i;
				foreach my $fr (@found) {
					$i++;
					my $n = $fr->[0];
					my $mb = $fr->[1];
					printf "%4d) %-60s - %6dMB\n",$i,$n,$mb;
				}
				printf "Available space: %6dMB\n",$availmb;
				my $j;
				while (1) {
					$j = prompt("Your choice","0-$i","0");
					if ($j < 0 || $j > $i) {
						print "Bad selection $j\n";
						next;
					}
					last;
				}
				next if ($j == 0);
				$sel = $found[$j-1];
			} else {
				$sel = $found[0];
			}

			next unless (defined($sel));
			my $n = $sel->[0];
			print "Adding $n...";
			my $mb = $sel->[1];
			if ($availmb > $mb) {
				$availmb -= $mb;
				push(@selected,$sel);
				print "OK\n";
			} else {
				print "No more space on the device!\n";
			}
		}
		my $totalmb = 0;
		my $i = 0;
		print "Summary:\n";
		foreach my $f (@selected) {
			my $n = $f->[0];
			push(@files,$n);
			my $mb = $f->[1];
			$totalmb += $mb;
			printf "%4d) %-60s - %6dMB\n",++$i,$n,$mb;
		}
		printf "Total size: %6dMB\n",$totalmb;
		last if (prompt("Is this correct?","y/n"));
		$askflag = 1;
	}
	print "Downloading...\n";
	getftp("$ISOSDIR/",@files);
} else {
	print "You can now install the ISO files manually.";
}

print "Done!\n";

END {
	print "Cleanup...\n";
	# Unmount everything
	umount($EFIMNT);
	umount($DATAMNT);
	# Delete mountpoints
	rmdir $EFIMNT;
	rmdir $DATAMNT;
	rmdir $REPODIR;
}

