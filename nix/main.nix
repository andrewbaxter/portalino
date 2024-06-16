{
  # String, key contents
  hostkey_priv
  # String, key contents
, hostkey_pub
  # String per `ssh-add -L`
, authorized_keys
  # WIFI SSID
, ssid
  # Spaghettinuum identity file path
, identity_file
  # Spaghettinuum admin token
, publisher_token
}:
let
  nixpkgsPath = <nixpkgs>;
  buildSystem = (configuration: import
    (nixpkgsPath + /nixos/lib/eval-config.nix)
    { modules = [ configuration ]; });
  persistent = "/mnt/persistent";
  wifiPasswordDir = "/run/wifi";
  wifiPasswordFile = "${wifiPasswordDir}/password";
  isoHostKey = "/to_etc/ssh/host_key";
  isoHostKeyPub = "/to_etc/ssh/host_key.pub";
in
buildSystem
  ({ config, modulesPath, pkgs, lib, ... }:
  {
    imports = [
      (nixpkgsPath + /nixos/modules/profiles/all-hardware.nix)
      ({ config, modulesPath, pkgs, lib, ... }:
        {
          config = {
            nixpkgs.localSystem.system = "x86_64-linux";
            boot.kernelParams = [ "nomodeset" "net.ifnames=0" ];
            boot.kernel.sysctl = { "net.ipv6.bindv6only" = true; };
            boot.consoleLogLevel = lib.mkDefault 7;
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
                "RuntimeMaxSize=100M"
              ];
            };

            # Routing/bridging
            networking.hostName = "spaghateway";
            networking.firewall.enable = false;
            networking.nftables.enable = true;
            networking.nftables.checkRuleset = false; # weird error with "filter" not supported on bridge, just with nix checks
            networking.nftables.ruleset = ''
              table bridge x_filter {
                chain x_forward {
                  type filter hook forward priority -300;

                  # Only wan and local hosts can communicate over ivp6, not router
                  ether type ip6 iifname {enp2s0, enp1s0} oifname {enp2s0, enp1s0} accept

                  # Prevent ipv4 from leaking. Internet traffic must be ipv6
                  ether type {arp, ip, icmp} iifname {pub, enp1s0} oifname {pub, enp1s0} accept

                  drop
                }
              }
            '';
            networking.dhcpcd.enable = false;
            networking.useDHCP = false;
            systemd.network.enable = true;
            systemd.network.netdevs.pub = {
              netdevConfig.Kind = "bridge";
              netdevConfig.Name = "br0";
            };
            systemd.network.networks.own = {
              matchConfig.Name = "br0";
              address = [
                "192.168.1.1/24"
              ];
              networkConfig.ConfigureWithoutCarrier = "yes";
              networkConfig.DHCPServer = "yes";
              dhcpServerConfig.EmitDNS = "yes";
              dhcpServerConfig.DNS = "_server_address";
            };
            systemd.network.networks.isp = {
              matchConfig.Name = "eth0";
              networkConfig.Bridge = "br0";
              networkConfig.ConfigureWithoutCarrier = "yes";
            };
            systemd.network.networks.lan = {
              matchConfig.Name = "eth1";
              networkConfig.Bridge = "br0";
              networkConfig.ConfigureWithoutCarrier = "yes";
            };
            #systemd.services.systemd-networkd.environment.SYSTEMD_LOG_LEVEL = "debug";
            #systemd.timers.dbg = {
            #  wantedBy = [ "timers.target" ];
            #  timerConfig = {
            #    OnBootSec = "1m";
            #    OnUnitActiveSec = "1m";
            #    Unit = "dbg.service";
            #  };
            #};
            #systemd.services.dbg = {
            #  script = ''
            #    set -eux
            #    ${pkgs.iproute2}/bin/ip addr
            #  '';
            #  serviceConfig = {
            #    Type = "oneshot";
            #  };
            #};

            # Wifi
            services.hostapd.enable = true;
            systemd.services.wifi_password = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig.Type = "oneshot";
              startLimitIntervalSec = 0;
              serviceConfig.Restart = "on-failure";
              serviceConfig.RestartSec = 60;
              script = ''
                set -eux
                mkdir -p ${wifiPasswordDir}
                # Every environment except bash has a trim function AFAIK
                ${pkgs.pwgen}/bin/pwgen --no-capitalize 8 | tr -d '[:space:]' > ${wifiPasswordFile}
                ${pkgs.qrencode}/bin/qrencode \
                  --type=svg \
                  --output=${wifiPasswordDir}/qr.svg \
                  <(printf 'WIFI:T:WPA;S:%s;P:%s;;' ${ssid} $(cat ${wifiPasswordFile})) \
                  ;
                ${pkgs.gnused}/bin/sed -e "s/PASSWORD/$(cat ${wifiPasswordFile})/" < ${./wifi_index.html} > ${wifiPasswordDir}/index.html
              '';
            };
            services.hostapd.radios.wlan0 = {
              networks.wlan0 = {
                settings.bridge = "br0";
                ssid = ssid;
                authentication = {
                  mode = "wpa2-sha256";
                  wpaPasswordFile = wifiPasswordFile;
                };
              };
            };

            # Disk
            systemd.services.persistent =
              {
                wantedBy = [ "multi-user.target" ];
                serviceConfig.Type = "oneshot";
                startLimitIntervalSec = 0;
                serviceConfig.Restart = "on-failure";
                serviceConfig.RestartSec = "60";
                serviceConfig.ExecStart =
                  let
                    name = "setup_persistent";
                    root = pkgs.writeShellApplication
                      {
                        name = "setup_persistent";
                        runtimeInputs = [ pkgs.util-linux pkgs.e2fsprogs ];
                        text = lib.concatStringsSep " " [
                          "${pkgs.python3}/bin/python3 -u ${./nixshared/persistent/setup_persistent.py} ${persistent}"
                        ];
                      };
                  in
                  "${root}/bin/${name}";
              };

            # Spaghettinuum
            systemd.services.spagh =
              let
                pkg =
                  pkgs.callPackage
                    ({ lib
                     , rustPlatform
                     , pkg-config
                     , nettle
                     , cargo
                     , rustc
                     , capnproto
                     , pcsclite
                     , sqlite
                     }:
                      rustPlatform.buildRustPackage rec {
                        pname = "spagh";
                        version = "0.0.0";
                        src = ../spaghettinuum;
                        # Based on final path element of src
                        sourceRoot = "spaghettinuum/spaghettinuum";
                        # For build.rs:
                        # Source is copied over with all the files read only for some reason.
                        # Make a new tree as the build user and make the files writable.
                        preConfigure = ''
                          cd ../../
                          cp -r spaghettinuum s
                          chmod -R u+w s
                          cd s/spaghettinuum
                        '';
                        cargoLock = {
                          lockFile = ../spaghettinuum/spaghettinuum/Cargo.lock;
                        };
                        buildInputs = [
                          nettle
                          pcsclite
                          sqlite
                        ];
                        nativeBuildInputs = [
                          pkg-config
                          cargo
                          rustc
                          rustPlatform.bindgenHook
                          capnproto
                        ];
                      })
                    { };
                config = pkgs.writeText "spagh_config" (builtins.toJSON {
                  persistent_dir = "${persistent}/spagh";
                  identity = {
                    local = identity_file;
                  };
                  global_addrs = [
                    {
                      from_interface = {
                        ip_version = "v6";
                        name = "eth0";
                      };
                    }
                  ];
                  node = {
                    bind_addr = "[::]:43890";
                    bootstrap = [ ];
                  };
                  publisher = {
                    bind_addr = "[::]:43891";
                  };
                  resolver = {
                    dns_bridge = {
                      udp_bind_addrs = [ "0:53" ];
                    };
                  };
                  admin_token = publisher_token;
                  api_bind_addrs = [
                    "[::]:12434"
                  ];
                  content = [
                    {
                      bind_addrs = [
                        "[::]:443"
                      ];
                      mode = {
                        static_files = {
                          content_dir = wifiPasswordDir;
                        };
                      };
                    }
                  ];
                });
              in
              {
                after = [ "wifi_password.service" "persistent.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig.Type = "simple";
                startLimitIntervalSec = 0;
                serviceConfig.Restart = "on-failure";
                serviceConfig.RestartSec = 60;
                script = ''
                  set -xeu
                  exec ${pkg}/bin/spagh-node --config ${config}
                '';
              };

            # Admin
            users = {
              users = {
                root = {
                  #hashedPassword = "!";
                  password = "abcd";
                  openssh.authorizedKeys.keys = authorized_keys;
                };
              };
            };
            environment.systemPackages = [
              pkgs.usbutils
              pkgs.pciutils
              pkgs.strace
              pkgs.iproute2
              pkgs.tcpdump
              pkgs.vim
              pkgs.curl
              pkgs.bash
              pkgs.psmisc
              pkgs.lshw
              (pkgs.writeShellScriptBin "nftables_debug" ''
                ${pkgs.nftables}/bin/nft add chain bridge x_filter x_trace { type filter hook prerouting priority -301\; }
                function cleanup {
                  ${pkgs.nftables}/bin/nft delete chain bridge x_filter x_trace
                }
                trap cleanup INT
                ${pkgs.nftables}/bin/nft add rule bridge x_filter x_trace "$@" meta nftrace set 1
                ${pkgs.nftables}/bin/nft monitor trace
              '')
            ];
            fileSystems = {
              "/etc/ssh/host_key" = {
                device = "/iso/${isoHostKey}";
                options = [ "bind" ];
              };
              "/etc/ssh/host_key.pub" = {
                device = "/iso/${isoHostKeyPub}";
                options = [ "bind" ];
              };
            };
            services.openssh = {
              enable = true;
              listenAddresses = [{
                addr = "0";
                port = 22;
              }];
              settings = {
                PasswordAuthentication = false;
                KbdInteractiveAuthentication = false;
              };
              hostKeys = [
                {
                  path = "/etc/ssh/host_key";
                  type = "ed25519";
                }
              ];
            };
            systemd.services.sshd = {
              after = [
                "network-online.target"
              ];
              startLimitIntervalSec = 0;
              serviceConfig.Restart = "always";
              serviceConfig.RestartSec = 60;
            };
          };
        })
      (import ./nixshared/iso/mod.nix {
        nixpkgsPath = nixpkgsPath;
        extraFiles = [
          {
            source = pkgs.writeText "hostkey_priv" "${hostkey_priv}\n";
            target = isoHostKey;
          }
          {
            source = pkgs.writeText "hostkey_pub" hostkey_pub;
            target = isoHostKeyPub;
          }
        ];
      })
    ];
  })
