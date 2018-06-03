package Device::GBA;
use strict;
use warnings;
use integer;
use IO::Termios;
use Fcntl;
use Time::HiRes;
use Device::BusPirate;
use File::stat;
use Term::ProgressBar;

# ABSTRACT: Perl Interface to the Gameboy Advance
# VERSION

use Carp;

=pod

=encoding utf8

=head1 NAME

Device::GBA - Perl Interface to the Gameboy Advance
=head1 SYNOPSIS

    use Device::GBA;

    my $gba = Device::GBA->new(buspirate => '/dev/ttyUSB0') or die "No such device!\n";
    $gba->upload('helloworld.gba');


=head1 METHODS AND ARGUMENTS

=over 4

=item new()

Opens specified device and returns the corresponding object reference. Returns undef
if an attempt to open the device has failed. Accepts following parameters:

=over 4

=item B<buspirate>

COM port or handle of the BusPirate connected to the Gameboy Advance.

=item B<spi>

L<Device::BusPirate::Mode::SPI> instance.

=item B<verbose>

if true, methods on this instance will narrate what they're doing. Default is C<0>.

=back

=cut

sub new {
    my $class = shift;
    my $self = {
        verbose => 0,
        bitrate   => '125k',
        @_
    };

    $self->{log} = $self->{verbose} ? sub { printf @_ } : sub { };

    if (!$self->{spi}) {
        if (ref $self->{buspirate} ne 'Device::BusPirate') {
            $self->{buspirate} = new_buspirate('Device::BusPirate', serial => $self->{buspirate}, %$self) or return;
        }
        $self->{spi} = $self->{buspirate}->enter_mode( "SPI" )->get;
    }

    $self->{spi}->configure(mode => 3, speed => $self->{bitrate})->get;

    bless $self, $class;
    return $self;
}

sub new_buspirate
{
   my $class = shift;
   my %args = @_;

   my $serial = $args{serial} || Device::BusPirate::BUS_PIRATE;
   my $baud   = $args{baud} || 115200;

   sysopen my $fd, $serial, O_RDWR|O_NDELAY|O_NOCTTY
      or croak "Cannot open serial port $serial - $!";
   my $fh = IO::Termios->new($fd)
      or croak "Cannot wrap serial port $serial - $!";
   $fh->set_mode( "$baud,8,n,1" )
      or croak "Cannot set mode on serial port $serial";

   $fh->setflag_icanon( 0 );
   $fh->setflag_echo( 0 );

   $fh->blocking( 0 );
   $fh->setflag_cread( 1 );
   $fh->setflag_clocal( 1 );

   return bless {
      fh => $fh,
      alarms => [],
      readers => [],
   }, $class;
}

=item upload

    $gba->upload($firmware_file)

Reads in I<$firmware_file> and uploads it to the Gameboy Advance.

=cut

sub upload {
    my $self = shift;
    my $firmware = shift;

    open my $fh, "<:raw", $firmware or croak "Can't open file `$firmware': $!\n";
    $self->log(".....Opening GBA file readonly\r\n");

    my $fsize = stat($firmware)->size;
    $fsize = ($fsize+0x0f)&0xfffffff0;

    if($fsize > 256 * 1024)
    {
        croak ("Err: Max file size 256kB\n");
    }

    local $/ = \2;

    $self->log(".....GBA file length 0x%08x\r\n\n", $fsize);
    $self->log("BusPirate(mstr) GBA(slave) \r\n\n");

    $self->spi_handshake(0x00006202, 0x72026202, "Looking for GBA");

    $self->spi_writeread(0x00006202, "Found GBA");
    $self->spi_writeread(0x00006102, "Recognition OK");

    my $fcnt;
    for($fcnt = 0; $fcnt < 192; $fcnt += 2) {
        $self->spi_writeread(unpack 'S<', <$fh>);
    }

    $self->spi_writeread(0x00006200, "Transfer of header data complete");
    $self->spi_writeread(0x00006202, "Exchange master/slave info again");

    $self->spi_writeread(0x000063d1, "Send palette data");

    my $r = $self->spi_writeread(0x000063d1, "Send palette data, receive 0x73hh****");

    my $m = (($r & 0x00ff0000) >>  8) + 0xffff00d1;
    my $h = (($r & 0x00ff0000) >> 16) + 0xf;

    $r = $self->spi_writeread(((($r >> 16) + 0xf) & 0xff) | 0x00006400, "Send handshake data");
    $r = $self->spi_writeread(($fsize - 0x190) / 4, "Send length info, receive seed 0x**cc****");

    my $f = ((($r & 0x00ff0000) >> 8) + $h) | 0xffff0000;
    my $c = 0x0000c387;


    my $progress = Term::ProgressBar->new({
            name   => 'Upload',
            count  => $fsize,
            ETA    => 'linear',
            silent => not $self->{verbose}
    });
    local $/ = \4;

    for (; $fcnt < $fsize; $fcnt += 4) {
        my $chunk = <$fh> // '';
        $chunk .= "\0" x (4 - length $chunk);
        my $w = unpack('L<', $chunk);
        $c = crc($w, $c);
        $m = ((0x6f646573 * $m) & 0xFFFFFFFF) + 1;
        my $data = $w ^ ((~(0x02000000 + $fcnt)) + 1) ^ $m ^ 0x43202f2f;
        $self->spi_writeread($data);

        $progress->update($fcnt);
    }

    $c = crc($f, $c);

    $self->spi_handshake(0x00000065, 0x00750065, "\nWait for GBA to respond with CRC");

    $self->spi_writeread(0x00000066, "GBA ready with CRC");
    $self->spi_writeread($c,         "Let's exchange CRC!");

    $self->log("CRC ...hope they match!\n");
    $self->log("MultiBoot done\n");
}

=item spi_writeread

    $miso = $gba->spi_writeread($mosi)

reads and writes 32 bit from the SPI bus.

=cut

sub spi_writeread {
    my $self = shift;
    my ($w, $msg) = @_;
    my $r = unpack 'L>', $self->{spi}->writeread(pack 'L>', shift)->get;
    $self->log("0x%08x 0x%08x  ; %s\n", $r , $w, $msg) if defined $msg;
    return $r;
}

sub spi_handshake {
    my $self = shift;
    my ($w, $expected, $msg) = @_;
    $self->log("%s 0x%08x\n", $msg, $expected) if defined $msg;

    while ($self->spi_writeread($w) != $expected) {
        sleep 0.01;
    }
}


=item crc

    $c = Device::GBA::crc($w, [$c = 0x0000c387])

Calculates CRC for word C<$w> and CRC C<$c> according to the algrithm used by the GBA multiboot protocol.

=cut

sub crc
{
    my $w = shift;
    my $c = shift // 0x0000c387;
    for (my $bit = 0; $bit < 32; $bit++) {
        if(($c ^ $w) & 0x01) {
            $c = ($c >> 1) ^ 0x0000c37b;
        } else {
            $c = $c >> 1;
        }

        $w = $w >> 1;
    }

    return $c;
}

sub log { my $log = shift->{'log'}; goto $log }


1;
__END__

=back

=head1 GIT REPOSITORY

L<http://github.com/athreef/Device-GBA>

=head1 SEE ALSO

L<gba> -- The command line utility

=head1 AUTHOR

Ahmad Fatoum C<< <athreef@cpan.org> >>, L<http://a3f.at>

Based on The uploader written by Ken Kaarvik.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2018 Ahmad Fatoum

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
