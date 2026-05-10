{ ppp_user
, ppp_password
, override_mtu ? null
, ssh_authorized_keys_dir ? null
}:
let
  const = import ./constants.nix;
  buildSystem = (configuration: import
    (const.nixpkgsPath + /nixos/lib/eval-config.nix)
    { modules = [ configuration ]; });
  lan_ip = "192.168.1.1";
  lan_prefix = 16;
  lan_dhcp_start = "192.168.2.1";
  lan_dhcp_end = "192.168.2.254";
in
buildSystem ({ ... }: {
  imports = [
    (import ./base.nix { ssh_authorized_keys_dir = ssh_authorized_keys_dir; })
    (import ./ipv6_bridge.nix { override_mtu = override_mtu; })
    ({ pkgs, lib, ... }: {
      config = {
        networking.jool.enable = true;
        networking.jool.nat64.default = { };

        systemd.network.networks.br0 = {
          address = [ "${lan_ip}/${builtins.toString lan_prefix}" ];
        };

        services.dnsmasq = {
          enable = true;
          settings = {
            interface = "br0";
            bind-interfaces = true;
            # Don't read /etc/resolv.conf; forward to spaghettinuum directly
            no-resolv = true;
            server = [ "127.0.0.1" ];
            dhcp-range = [ "${lan_dhcp_start},${lan_dhcp_end},24h" ];
            dhcp-option = [
              "option:router,${lan_ip}"
              "option:dns-server,${lan_ip}"
            ];
          };
        };

        networking.nftables.ruleset = ''
          table ip my_nat {
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              oif "ppp0" masquerade
            }
          }

          table ip my_filter {
            chain input {
              type filter hook input priority 0; policy accept;
              iif "br0" udp dport 67 accept
              iif "br0" udp dport 53 accept
              iif "br0" tcp dport 53 accept
            }
            chain forward {
              type filter hook forward priority 0; policy accept;
              ct state { established, related } accept
              iif "br0" oif "ppp0" accept
            }
          }
        '';

        services.miniupnpd = {
          enable = true;
          externalInterface = "ppp0";
          internalIPs = [ "${lan_ip}/br0" ];
          natpmp = true;
          firewall = "nftables";
        };

        services.pppd = {
          # - `pppd` on `eth0` when `eth0` is enslaved to the bridge doesn't work
          #
          #   Bridge/ipv6 traffic was fine, but pppd never managed a connection. I think this is due to `rx_handler` (<https://cnly.github.io/2018/11/09/conflicts-and-limitations-of-bridge-and-macvlan-devices.html>) sucking up all traffic for the bridge, so `pppd` didn't see any.
          #
          # - I tried making a `macvlan` off of enslaved `eth0` to use the `macvlan` for `pppd`
          #
          #   This resulted in an error: (kernel only allows one `rx_handler`, per above link)
          #
          # - I tried making `pppd` run on `eth0` and enslaving a `macvlan` to the bridge.
          #
          #   `pppd` was fine, but ipv6 traffic didn't work. This is because `macvlan` only listens for its own mac address, but return traffic was for other mac addresses from the bridge.
          #
          # The final solution was to run `pppd` on the `br0` interface. I believe `pppoe` is a layer 2 protocol, so it does direct MAC-address communcation.
          #
          # I did encounter `ppp0` not receiving responses once which led me to think this didn't work either, but I haven't reproduced it since and it actually works now.
          enable = true;
          peers.main = {
            name = "main";
            enable = true;
            autostart = true;
            config = lib.concatStringsSep "\n" [
              "plugin pppoe.so"
              "nic-br0"
              "persist"
              "maxfail 0"
              "holdoff 5"
              "defaultroute"
              "noauth"
              "name \"${ppp_user}\""
              "password \"${ppp_password}\""
            ];
          };
        };
        systemd.services.pppd-main = {
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "always";
          serviceConfig.RestartSec = lib.mkForce 60;
        };
      };
    })
  ];
})
