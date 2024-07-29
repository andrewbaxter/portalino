{}:
let
  nixpkgsPath = <nixpkgs>;
  buildSystem = (configuration: import
    (nixpkgsPath + /nixos/lib/eval-config.nix)
    { modules = [ configuration ]; });
  wifiPasswordDir = "/run/wifi";
  wifiPasswordFile = "${wifiPasswordDir}/password";
  isoHostKey = "/to_etc/ssh/host_key";
  isoHostKeyPub = "/to_etc/ssh/host_key.pub";
  nftableIpv6 = "x_table_ipv6";
in
buildSystem
  ({ ... }:
  {
    imports = [
      (nixpkgsPath + /nixos/modules/profiles/all-hardware.nix)
      ./volumesetup/source/module.nix
      ({ config, modulesPath, pkgs, lib, ... }:
        {
          config = {
            nixpkgs.localSystem.system = "x86_64-linux";
            boot.kernelParams = [ "nomodeset" "net.ifnames=0" ];
            boot.kernel.sysctl = {
              "net.ipv6.bindv6only" = true;
              "net.ipv6.conf.all.forwarding" = true;
            };
            boot.consoleLogLevel = lib.mkDefault 7;
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
                "RuntimeMaxSize=100M"
              ];
            };

            networking.hostName = "portalino";

            # Disk 
            volumesetup.enable = true;

            # Glue
            systemd.services.glue =
              let
                pkg =
                  pkgs.callPackage
                    ({ lib
                     , rustPlatform
                     , rustc
                     , cargo
                     , makeWrapper
                     }:
                      rustPlatform.buildRustPackage rec {
                        pname = "glue";
                        version = "0.0.0";
                        cargoLock. lockFile = ../software/glue/Cargo.lock;
                        src = ./glue;
                        cargoBuildFlags = [ "--bin=setup" ];
                        nativeBuildInputs = [
                          cargo
                          rustc
                          rustPlatform.bindgenHook
                          makeWrapper
                        ];
                        postFixup =
                          let
                            path = lib.makeBinPath [
                              pkgs.systemd
                              pkgs.ppp
                              pkgs.dhcpcd
                              pkgs.util-linux
                            ];
                          in
                          ''
                            wrapProgram $out/bin/setup --prefix PATH : ${path}
                          '';
                      })
                    { };
              in
              {
                after = [ "volumesetup.service" ];
                requires = [ "volumesetup.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig.Type = "oneshot";
                startLimitIntervalSec = 0;
                serviceConfig.Restart = "on-failure";
                serviceConfig.RestartSec = 60;
                script = ''
                  set -xeu
                  exec ${pkg}/bin/glue
                '';
              };

            # Network interfaces, routing
            networking.dhcpcd.enable = false;
            networking.useDHCP = false;
            systemd.network.enable = true;
            systemd.network.networks.wan = {
              matchConfig.Name = "eth0";
              DHCP = "ipv6";
              dhcpV6Config.DUIDType = "link-layer";
              # This interface doesn't get an address (no IA_NA in dhcp resp, no PIO in RA) so
              # don't wait for one.  This puts the interface in "configured" state.
              dhcpV6Config.UseAddress = "no";
              dhcpV6Config.UseDNS = "no";
            };
            systemd.network.netdevs.lan_bridge = {
              netdevConfig.Kind = "bridge";
              netdevConfig.Name = "br0";
            };
            systemd.network.networks.self = {
              matchConfig.Name = "br0";
              networkConfig.IPv6SendRA = "yes";
              networkConfig.DHCPPrefixDelegation = "yes";
              ipv6SendRAConfig.EmitDNS = "yes";
              ipv6SendRAConfig.DNS = "_link_local";
            };
            systemd.network.networks.lan = {
              matchConfig.Name = "eth1";
              networkConfig.Bridge = "br0";
            };
            services.hostapd.enable = true;
            services.hostapd.radios.wlan0 = {
              dynamicConfigScripts = {
                glue = pkgs.writeShellScript "hostapd-dynamic-config" ''
                  HOSTAPD_CONFIG=$1
                  cat /run/wifidynamic/config >> "$HOSTAPD_CONFIG"
                '';
              };
              networks.wlan0 = {
                settings.bridge = "br0";
                ssid = "";
                authentication = {
                  mode = "wpa2-sha256";
                  wpaPasswordFile = "/run/wifidynamic/password";
                };
              };
            };
            systemd.services.hostapd = {
              after = [ "glue.service" ];
              unitConfig.ConditionPathExists = "/run/wifidynamic";
            };

            # Tentative IPv4 setup
            networking.jool.enable = true;
            networking.jool.nat64.default = { };
            systemd.services.jool-nat64-default.wantedBy = lib.mkForce [ ];
            services.pppd = {
              enable = true;
              peers.main = {
                name = "main";
                enable = true;
                autostart = false;
                config = lib.concatStringsSep "\n" [
                  "plugin rp-pppoe.so"
                  "eth0"
                  "persist"
                  "maxfail 0"
                  "holdoff 5"
                  "defaultroute"
                  "noauth"
                  "file /tmp/pppdynamic/config"
                ];
              };
            };

            # Firewall
            networking.firewall.enable = false;
            #networking.nftables.enable = true;
            systemd.services.nftables = {
              after = [
                "hostapd.service"
              ];
              startLimitIntervalSec = 0;
              serviceConfig.Restart = "on-failure";
              serviceConfig.RestartSec = 60;
            };
            networking.nftables.checkRuleset = false; # checker is rejecting flowtables 
            networking.nftables.ruleset = ''
              define z_wan = eth0
              define z_self = br0
              define z_lan = eth1
              define z_lanwifi = wlan0
              table ip6 ${nftableIpv6} {
                # Application traffic (layer 3) ---
                # Layer 2 traffic is always accepted.
                chain x_chain_self {
                  type filter hook input priority 0; policy drop;
                  ct state { established, related } accept
                  oifname != $z_self accept
                  udp dport { 43890 } accept
                  tcp dport { 43891, 12434 } accept
                }

                # Routed (layer 3) ---
                chain x_chain_fwd_interface {
                  type filter hook forward priority 0; policy drop;
                  iifname { $z_wan, $z_self } oifname { $z_wan, $z_self } accept
                }
                flowtable x_ft_hw_offload {
                    hook ingress priority 0
                    devices = { $z_wan, $z_lan, $z_lanwifi }
                }
                chain x_fwd_chain_conntrack {
                  type filter hook forward priority 0; policy drop;
                  ip6 nexthdr { tcp, udp } flow add @x_ft_hw_offload
                  ct state { new, established, related } accept
                }
              }
              table ip x_table_ipv4 {
                # Routed (layer 3) ---
                chain x_chain_reject {
                  type filter hook forward priority 0; policy drop;
                }
              }
            '';
            systemd.services.systemd-networkd.environment.SYSTEMD_LOG_LEVEL = "debug";
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

            # DNS64, Spaghettinuum
            # Get local dns out of the way
            services.resolved.enable = true; # Seems to be on anyway, despite default off
            services.resolved.fallbackDns = [ ];
            #services.resolved.extraConfig = lib.concatStringsSep "\n" [
            #  "DNSStubListener=no"
            #  "DNSStubListenerExtra=udp:127.0.0.1:153"
            #];
            #            systemd.services.spagh =
            #              let
            #                pkg = import ./spaghettinuum/source/package.nix
            #                config = pkgs.writeText "spagh_config" (builtins.toJSON {
            #                  persistent_dir = "${persistent}/spagh";
            #                  identity = {
            #                    local = identity_file;
            #                  };
            #                  global_addrs = [
            #                    {
            #                      from_interface = {
            #                        ip_version = "v6";
            #                        name = "br0";
            #                      };
            #                    }
            #                  ];
            #                  node = {
            #                    bind_addr = "[::]:43890";
            #                    bootstrap = [ ];
            #                  };
            #                  publisher = {
            #                    bind_addr = "[::]:43891";
            #                  };
            #                  resolver = {
            #                    dns_bridge = {
            #                      udp_bind_addrs = [ "0:53" ];
            #                      upstream = "127.0.0.1:153";
            #                    };
            #                  };
            #                  admin_token = {
            #                    inline = publisher_token;
            #                  };
            #                  api_bind_addrs = [
            #                    "[::]:12434"
            #                  ];
            #                });
            #              in
            #              {
            #                after = [ "nftables.service" "persistent.service" ];
            #                wantedBy = [ "multi-user.target" ];
            #                serviceConfig.Type = "simple";
            #                startLimitIntervalSec = 0;
            #                serviceConfig.Restart = "on-failure";
            #                serviceConfig.RestartSec = 60;
            #                script = ''
            #                  set -xeu
            #                  exec ${pkg}/bin/spagh-node --config ${config}
            #                '';
            #              };

            # Admin
            users = {
              users = {
                root = {
                  #hashedPassword = "!";
                  password = "abcd";
                };
              };
            };
            environment.systemPackages = [
              pkgs.usbutils
              pkgs.pciutils
              pkgs.strace
              pkgs.iproute2
              pkgs.tcpdump
              pkgs.tshark
              pkgs.termshark
              pkgs.vim
              pkgs.curl
              pkgs.bash
              pkgs.psmisc
              pkgs.lshw
              pkgs.ndisc6
              (pkgs.writeShellScriptBin "nftables_debug" (
                let chain = "x_trace"; in ''
                  ${pkgs.nftables}/bin/nft add chain ip6 ${nftableIpv6} ${chain} { type filter hook prerouting priority -301\; }
                  function cleanup {
                    ${pkgs.nftables}/bin/nft delete chain ip6 ${nftableIpv6} ${chain}
                  }
                  trap cleanup INT
                  ${pkgs.nftables}/bin/nft add rule ip6 ${nftableIpv6} ${chain} "$@" meta nftrace set 1
                  ${pkgs.nftables}/bin/nft monitor trace | grep -v ${chain}
                ''
              ))
            ];
          };
        })
      (import ./nixshared/iso/mod.nix {
        nixpkgsPath = nixpkgsPath;
        extraFiles = [ ];
      })
    ];
  })
