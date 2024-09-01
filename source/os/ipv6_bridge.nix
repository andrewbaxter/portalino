{ ... }:
let
  const = import ./constants.nix;
  inject_dns_queue = builtins.toString 0;
  inject_dns_mark = builtins.toString 1;
in
{
  imports = [
    ({ pkgs, lib, ... }: {
      config = {
        systemd.network.networks.eth0 = {
          matchConfig.Name = "eth0";
          networkConfig.Bridge = "br0";
          linkConfig.Group = 10;
        };
        systemd.network.networks.br0 = {
          matchConfig.Name = "br0";
          linkConfig.Group = 12;
        };
        systemd.services.setup_nftables_jool_mangle = {
          # jool only listens on layer 3 prerouting, so need to forcibly redirect bridge traffic. Pointing
          # it at the local bridge interface passes it through bridge-input then ip6-prerouting and is captured by
          # jool properly.
          #
          # I guess pkttype is some meta routing information added earlier during processing that needs to be
          # manually reset. Without that the traffic gets dropped between bridge-input and ip6-prerouting.
          after = [ "nftables.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "on-failure";
          serviceConfig.RestartSec = 60;
          script = ''
            bridge_addr=$(${pkgs.iproute2}/bin/ip --json link show br0 | ${pkgs.jq}/bin/jq -r .[0].address)
            ${pkgs.nftables}/bin/nft -f <(sed -e "s/__BRIDGE_ADDR/$bridge_addr/g" ${./ipv6_bridge_template_jool_mangle.nftables})
          '';
        };
        networking.nftables.checkRuleset = false;
        networking.nftables.ruleset =
          let
            lan_elements = lib.concatStringsSep ", " (builtins.genList
              (i: "eth${builtins.toString (i + 1)}")
              const.lanCount);
          in
          ''
            #table ip6 my_table {
            #  chain my_chain_input_wan_br0 {
            #    # Allow spagh traffic in
            #    udp dport { ${ builtins.toString const.spaghWanDhtPort } } accept
            #    tcp dport { ${ builtins.toString const.spaghWanPublishPort }, ${ builtins.toString const.spaghWanApiPort } } accept
            #  }

            #  chain my_chain_input {
            #    type filter hook input priority 0; policy drop;

            #    ct state vmap { established : accept, related : accept, invalid : drop }

            #    iif lo accept

            #    meta l4proto ipv6-icmp accept

            #    # Allow all lan traffic
            #    iifgroup 11 oifgroup 12 accept

            #    # Allow restricted wan traffic
            #    iifgroup 10 oifgroup 12 goto my_chain_input_wan_br0
            #  }

            #  chain my_chain_add_flowtable {
            #    # Populated after all devices created
            #  }

            #  chain my_chain_forward {
            #    type filter hook forward priority 0; policy accept;

            #    ip6 nexthdr { tcp, udp } jump my_chain_add_flowtable
            #  }
            #}

            table bridge my_table {
              chain my_chain_add_flowtable {
                # Populated after all devices created
              }

              chain my_chain_forward {
                type filter hook forward priority 0; policy drop;
          
                # Intercept RAs + DHCPv6 responses and pass them to glue modify_ra which consumes/modifies
                meta l4proto ipv6-icmp icmpv6 type nd-router-advert mark != ${inject_dns_mark} queue num ${inject_dns_queue}
                meta l4proto udp th sport 547 mark != ${inject_dns_mark} queue num ${inject_dns_queue}

                ip6 nexthdr { tcp, udp } jump my_chain_add_flowtable

                ct state vmap { established : accept, related : accept, invalid : drop }

                ether type ip6 accept
              }
            }
          '';
        systemd.services.glue_inject_dns = {
          wantedBy = [ "nftables.service" ];
          serviceConfig.Type = "simple";
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "always";
          serviceConfig.RestartSec = 60;
          script =
            let
              pkg = (import ./package_glue.nix) { pkgs = pkgs; };
            in
            ''
              set -xeu
              exec ${pkg}/bin/inject_dns --nf-queue ${inject_dns_queue} --nf-mark ${inject_dns_mark} --interface br0
            '';
        };
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "nftables_debug" (
            let chain = "my_chain_trace"; in ''
              set -xeu
              ${pkgs.nftables}/bin/nft add chain bridge my_table ${chain} { type filter hook prerouting priority -301\; }
              ${pkgs.nftables}/bin/nft add chain ip6 my_table ${chain} { type filter hook prerouting priority -301\; }
              function cleanup {
                ${pkgs.nftables}/bin/nft delete chain bridge my_table ${chain}
                ${pkgs.nftables}/bin/nft delete chain ip6 my_table ${chain}
              }
              trap cleanup INT
              ${pkgs.nftables}/bin/nft add rule bridge my_table ${chain} "$@" meta nftrace set 1
              ${pkgs.nftables}/bin/nft add rule ip6 my_table ${chain} "$@" meta nftrace set 1
              ${pkgs.nftables}/bin/nft monitor trace | ${pkgs.gnugrep}/bin/grep -v ${chain}
            ''
          ))
        ];
      };
    })
  ];
}
