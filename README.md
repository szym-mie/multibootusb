# Multiboot USB

Customized fork of the original [Multiboot USB](https://mbusb.aguslr.com/) project.

## About

Compared to the original:
- increased portablility - rewritten the Bash script to Perl. Requires only the POSIX make, fdisk and basic Unix utilites;
- automatic FTP sync - the program searches for ISO files on the remote host and attempts to download them, the users can then choose which OSes they want on the disk;
- checkpoints, to skip long operations that were already done;
- better logging ;P.

## Documentation

To make the configuration file compatible with this script, a FTP marker must be placed immediately before the line containing the path to the ISO file:

```
# +++FTP
for isofile in $isopath/antix*_amd64.iso; do
  if [ -e "$isofile" ]; then
...
```

The marker is a comment with the contents `+++FTP`. The path will be matched with this pattern: `/[A-Za-z0-9._*]+`.

The path to the remote files can be specified with the `-f` flag: `-f ftp://10.0.0.1/iso` or `-f ftp://iso.net/pub/`. The `-u` flag specifies the FTP user like so: `-u user` or `-u user:pass`.

## Acknowledgements

Thanks agulsr for figuring out the GRUB Multiboot inner workings.
