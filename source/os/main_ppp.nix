{ spaghettinuum_config
, ppp_user
, ppp_password
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
    ./ipv6_bridge.nix
    ({ pkgs, lib, ... }: {
      config = {
        systemd.network.networks.ipv4wan = {
          DHCP = "no";
        };
        # networking.jool.enable = true;
        # networking.jool.nat64.default = { };
        services.pppd = {
          # enable = true;
          enable = false; # debug
          peers.main = {
            name = "main";
            enable = true;
            autostart = true;
            config = lib.concatStringsSep "\n" [
              "plugin pppoe.so"
              "nic-eth0"
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
