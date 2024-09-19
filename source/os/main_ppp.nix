{ spaghettinuum_config
, ppp_user
, ppp_password
, override_mtu ? null
, ssh_authorized_keys_dir ? null
}:
let
  const = import ./constants.nix;
  buildSystem = (configuration: import
    (const.nixpkgsPath + /nixos/lib/eval-config.nix)
    { modules = [ configuration ]; });
in
buildSystem ({ ... }: {
  imports = [
    (import ./base.nix { spaghettinuum_config = spaghettinuum_config; ssh_authorized_keys_dir = ssh_authorized_keys_dir; })
    (import ./ipv6_bridge.nix { override_mtu = override_mtu; })
    ({ pkgs, lib, ... }: {
      config = {
        networking.jool.enable = true;
        networking.jool.nat64.default = { };
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
