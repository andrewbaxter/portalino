{ spaghettinuum_config
, ssh_authorized_keys_dir ? null
}:
let const = import ./constants.nix; in ({ ... }: {
  imports = [
    (const.nixpkgsPath + /nixos/modules/profiles/all-hardware.nix)
    ../rust/volumesetup/source/module.nix
    ({ pkgs, lib, ... }: {
      config = {
        nixpkgs.localSystem.system = "x86_64-linux";
        boot.kernelParams = [ "nomodeset" "net.ifnames=0" ];
        boot.kernel.sysctl = {
          "net.ipv6.bindv6only" = true;
          "net.ipv6.conf.all.forwarding" = true;
          # Get rid of the "clamping QRV from 1 to 2!" log spam (why)
          "net.ipv6.mld_qrv" = 1;
        };
        #boot.consoleLogLevel = lib.mkDefault 7;
        systemd.targets.sound.enable = false;
        #systemd.targets.getty = {
        #  # Prevent login terminal, prevent screen wipe
        #  enable = false;
        #};
        #services.logind = {
        #  extraConfig = lib.strings.concatStringsSep "\n" [
        #    "NAutoVTs=0"
        #    "ReserveVT=0"
        #  ];
        #};
        services.journald = {
          console = "/dev/tty0";
          extraConfig = lib.strings.concatStringsSep "\n" [
            "Storage=volatile"
            "RuntimeMaxUse=100M"
          ];
        };

        networking.hostName = "portalino";
        #users.users.root.hashedPassword = "!";

        # Disk 
        volumesetup.enable = true;

        # Glue
        systemd.services.glue =
          let
            pkg = (import ./package_glue.nix) { pkgs = pkgs; };
          in
          {
            after = [ "volumesetup.service" ];
            requires = [ "volumesetup.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = "yes";
            startLimitIntervalSec = 0;
            serviceConfig.Restart = "on-failure";
            serviceConfig.RestartSec = 60;
            script = ''
              set -xeu
              exec ${pkg}/bin/setup
            '';
          };
        systemd.services.info_http = {
          after = [ "glue.service" ];
          requires = [ "glue.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "simple";
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "always";
          serviceConfig.RestartSec = 60;
          script = ''
            set -xeu
            exec ${pkgs.caddy}/bin/caddy file-server --listen :80 --root /run/my_infohtml
          '';
        };

        # Network interfaces, routing
        networking.dhcpcd.enable = false;
        networking.useDHCP = false;
        systemd.network.enable = true;
        systemd.network.links.all = {
          matchConfig.OriginalName = "*";
          # Per jool docs, routers (+ esp jool) should have this disabled. Offload refers to hardware offload
          # of packet de-fragmentation. It's normally for application consumption, but if going back to the internet
          # the packets need to be re-fragmented which is slow.
          #
          # I guess linux automatically disables this when routing, but just to be sure (as jool instructs).
          linkConfig.GenericSegmentationOffload = "no";
          linkConfig.LargeReceiveOffload = "no";
        };
        systemd.network.netdevs.br0 = {
          netdevConfig.Kind = "bridge";
          netdevConfig.Name = "br0";
        };
        systemd.network.networks = builtins.listToAttrs ([
        ]
        ++ (builtins.genList
          (i:
            let ifIndex = builtins.toString (i + 1); in {
              name = "eth${ifIndex}";
              value = {
                matchConfig.Name = "eth${ifIndex}";
                linkConfig.Group = 11;
                networkConfig.Bridge = "br0";
                networkConfig.ConfigureWithoutCarrier = "yes";
              };
            })
          const.lanCount));
        services.hostapd.enable = true;
        boot.kernel.sysctl."net.ipv6.conf.wlan0.accept_ra" = 0; # gets an addr despite being bridged, but shouldn't
        boot.kernel.sysctl."net.ipv6.conf.wlan0.accept_dad" = 0; # same
        services.hostapd.radios.wlan0 = {
          networks.wlan0 = {
            settings.bridge = "br0";
            ssid = "";
            dynamicConfigScripts = {
              glue = pkgs.writeShellScript "hostapd-dynamic-config" ''
                HOSTAPD_CONFIG=$1
                sed -i '/^ssid=/d' "$HOSTAPD_CONFIG"
                cat /run/my_hostapd/config >> "$HOSTAPD_CONFIG"
              '';
            };
            authentication = {
              mode = "wpa2-sha256";
              wpaPasswordFile = "/run/my_hostapd/password";
            };
          };
        };
        systemd.services.hostapd = {
          after = [ "glue.service" ];
          postStart = ''
            ${pkgs.iproute2}/bin/ip link set wlan0 group 11
          '';
          unitConfig.ConditionPathExists = "/run/my_hostapd/password";
        };

        # Firewall - further configuration based on ipv6 mode
        networking.firewall.enable = false;
        networking.nftables.enable = true;
        systemd.services.nftables = {
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "on-failure";
          serviceConfig.RestartSec = 60;
        };
        # systemd.services.systemd-networkd.environment.SYSTEMD_LOG_LEVEL = "debug";

        # Ssh, admin
        services.openssh = {
          enable = true;
          settings.PasswordAuthentication = false;
          settings.KbdInteractiveAuthentication = false;
          listenAddresses = [{
            addr = "[::]";
            port = 22;
          }];
        };
        users.users.root.openssh.authorizedKeys.keyFiles = lib.lists.optionals (ssh_authorized_keys_dir != null) (
          map (x: ssh_authorized_keys_dir + "/${x}") (builtins.attrNames (builtins.readDir ssh_authorized_keys_dir))
        );
        environment.systemPackages = [
          # Basic tools
          pkgs.vim
          pkgs.curl
          pkgs.bash
          pkgs.psmisc
          pkgs.strace
          pkgs.jq
          pkgs.lsof

          # Hardware
          pkgs.usbutils
          pkgs.pciutils
          pkgs.lshw
          pkgs.e2fsprogs
          pkgs.smartmontools

          # Network
          pkgs.iproute2
          pkgs.tcpdump
          pkgs.tshark
          pkgs.termshark
          pkgs.ndisc6
          pkgs.dig
          pkgs.knot-dns
          pkgs.nftables
          pkgs.ethtool
        ];

        # Spaghettinuum
        services.resolved.enable = false;
        security.pki.certificateFiles = [
          (pkgs.fetchurl {
            url = "https://storage.googleapis.com/zlr7wmbe6/spaghettinuum_s.crt";
            # 2024-09-01
            hash = "sha256-AxxOtl1USf/86Xd4UhS6fTptaj+D9UqD1ertQqo4kEg=";
          })
        ];
        systemd.services.spaghettinuum =
          let
            pkg = import ../rust/spaghettinuum/source/package.nix { pkgs = pkgs; };
            config_path = pkgs.writeText "spaghettinuum_config" spaghettinuum_config;
          in
          {
            after = [ "glue.service" ];
            requires = [ "glue.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "simple";
            startLimitIntervalSec = 0;
            serviceConfig.Restart = "always";
            serviceConfig.RestartSec = 60;
            script = ''
              set -xeu
              exec ${pkg}/bin/spagh-node --config ${config_path}
            '';
          };
        networking.nameservers = [ "127.0.0.1" ];

        # DEBUG
        users.users.root.password = "abcd";
      };
    })
    (import ./nixshared/iso/mod.nix {
      nixpkgsPath = const.nixpkgsPath;
      extraFiles = [ ];
    })
  ];
})
