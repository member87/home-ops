# Partitioned by nixos-anywhere (disko). A BIOS boot partition and an ESP, so GRUB boots
# whether the VPS firmware is legacy BIOS or UEFI.
{ config, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = config.edge.disk;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        esp = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # disko adds the disk to boot.loader.grub.devices because of the EF02 partition.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
}
