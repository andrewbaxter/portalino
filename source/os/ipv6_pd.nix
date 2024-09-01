{ ... }:
let const = import ./constants.nix; in {
  imports = [
    ({ pkgs, lib, ... }: {
      config = {
        systemd.network.networks.ipv6wan = {
          matchConfig.Name = "eth0";
          linkConfig.Group = 10;
          dhcpV6Config.DUIDType = "link-layer";
          # This interface doesn't get an address (no IA_NA in dhcp resp, no PIO in RA) so
          # don't wait for one.  This puts the interface in "configured" state.
          dhcpV6Config.UseAddress = "no";
          dhcpV6Config.UseDNS = "no";
        };
        systemd.network.networks.br0 = {
          matchConfig.Name = "br0";
          linkConfig.Group = 12;
          networkConfig.IPv6SendRA = "yes";
          networkConfig.DHCPPrefixDelegation = "yes";
          ipv6SendRAConfig.EmitDNS = "yes";
          ipv6SendRAConfig.DNS = "_link_local";
        };
        #networking.nftables.checkRuleset = false;
        networking.nftables.ruleset = ''
          # Ipv4:
          # Since we set up no ipv4 routes aside from stuff happening internally to
          # pppd/jool and routes set up by them on those interfaces, ipv4 is effectively
          # blocked.

          # Ipv6:
          table ip6 my_table {
            # Input:
            chain my_chain_input_wan_br0 {
              # Allow spagh traffic in
              udp dport { ${ builtins.toString const.spaghWanDhtPort } } accept
              tcp dport { ${ builtins.toString const.spaghWanPublishPort }, ${ builtins.toString const.spaghWanApiPort } } accept
            }

            chain my_chain_input {
              type filter hook input priority 0; policy drop;
              ct state vmap { established : accept, related : accept, invalid : drop }

              iif lo accept

              meta l4proto ipv6-icmp accept

              iifgroup != 10 oifgroup 12 accept

              iifgroup 10 oifgroup 12 goto my_chain_input_wan_br0
            }

            # Forwarding:
            chain my_chain_add_flowtable {
              flow add @my_ft_hw_offload
            }

            chain my_chain_forward {
              type filter hook forward priority 0; policy drop;
              
              ip6 nexthdr { tcp, udp } jump my_chain_add_flowtable

              ct state vmap { established : accept, related : accept, invalid : drop }
            }
          }
        '';
        systemd.services.setup_flowtables.script =
          let
            lanElements = lib.concatStringsSep ", " (builtins.genList
              (i: "eth${builtins.toString (i + 1)}")
              const.lanCount);
          in
          ''
            set -xeu
            ${pkgs.nftables}/bin/nft 'add flowtable ip6 my_table my_ft_default { hook ingress priority 0; devices = { eth0, ${lanElements}, wlan0 }; }'
            ${pkgs.nftables}/bin/nft 'flush chain ip6 my_table my_chain_add_flowtable'
            ${pkgs.nftables}/bin/nft 'add rule ip6 my_table my_chain_add_flowtable flow add @my_ft_default'
          '';
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "nftables_debug" (
            let chain = "my_trace"; in ''
              set -xeu
              ${pkgs.nftables}/bin/nft add chain ip6 my_table ${chain} { type filter hook prerouting priority -301\; }
              function cleanup {
                ${pkgs.nftables}/bin/nft delete chain ip6 my_table ${chain}
              }
              trap cleanup INT
              ${pkgs.nftables}/bin/nft add rule ip6 my_table ${chain} "$@" meta nftrace set 1
              ${pkgs.nftables}/bin/nft monitor trace | ${pkgs.gnugrep}/bin/grep -v ${chain}
            ''
          ))
        ];
      };
    })
  ];
}
