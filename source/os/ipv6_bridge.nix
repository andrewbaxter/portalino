{ override_mtu ? null }: { ... }:
let
  const = import ./constants.nix;
  mangle_ip_configure_queue = builtins.toString 0;
  mangle_ip_configure_mark = builtins.toString 2;
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
        systemd.services.setup_nftables_mangle_jool = {
          # Jool only listens on layer 3 prerouting, so need to forcibly redirect bridge traffic. Pointing
          # it at the local bridge interface passes it through bridge-input then ip6-prerouting and is captured by
          # jool properly.
          #
          # I guess pkttype is some meta routing information added earlier during processing that needs to be
          # manually reset. Without that the traffic gets dropped between bridge-input and ip6-prerouting.
          after = [ "nftables.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = "yes";
          startLimitIntervalSec = 0;
          serviceConfig.Restart = "on-failure";
          serviceConfig.RestartSec = 60;
          script = ''
            bridge_addr=$(${pkgs.iproute2}/bin/ip --json link show br0 | ${pkgs.jq}/bin/jq -r .[0].address)
            ${pkgs.nftables}/bin/nft -f <(sed -e "s/__BRIDGE_ADDR/$bridge_addr/g" ${./ipv6_bridge_template_mangle_jool.nftables})
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
            table bridge my_table {
              chain my_chain_prerouting {
                type filter hook prerouting priority 0; policy accept;
          
                # Mark RAs + DHCPv6 responses to pass them to glue mangle_ip_configure which consumes/modifies.
                # Only want to modify the ones to forward - the ones destined locally are used
                # to set interface ips which are required for mangle_ip_configure to work (dep ordering).
                mark 0 meta l4proto ipv6-icmp icmpv6 type nd-router-advert mark set 1
                mark 0 meta l4proto udp th sport 547 mark set 1

                # Mark other traffic by originating network
                mark 0 iifgroup 10 mark set 10
                mark 0 iifgroup 11 mark set 11
                mark 0 iifgroup 12 mark set 12
              }

              chain my_chain_forward {
                type filter hook forward priority 0; policy accept;

                mark 1 queue num ${mangle_ip_configure_queue}
              }
            }

            table ip6 my_table {
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

                # Allow all lan traffic
                mark 11 accept

                # Allow restricted wan traffic
                mark 10 goto my_chain_input_wan_br0
              }
            }
          '';
        systemd.services.glue_mangle_ip_configure = {
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
              exec ${pkg}/bin/mangle_ip_configure \
                --nf-queue ${mangle_ip_configure_queue} \
                --nf-mark ${mangle_ip_configure_mark} \
                --interface br0 \
                ${lib.concatStringsSep " " (lib.lists.optionals (override_mtu != null) ["--mtu" (builtins.toString override_mtu)])} \
                ;
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
