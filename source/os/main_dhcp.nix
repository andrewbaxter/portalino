{ spaghettinuum_config
, ssh_authorized_keys_dir ? null
}:
let
  const = import ./constants.nix;
  buildSystem = (configuration: import
    (const.nixpkgsPath + /nixos/lib/eval-config.nix)
    { modules = [ configuration ]; });
  lan_count = 16;
in
buildSystem ({ ... }: {
  imports = [
    (import ./base.nix { spaghettinuum_config = spaghettinuum_config; ssh_authorized_keys_dir = ssh_authorized_keys_dir; })
    ./ipv6_bridge.nix
    ({ pkgs, lib, ... }: {
      config = {
        systemd.network.networks.ipv4wan = {
          DHCP = "ipv4";
        };
        networking.jool.enable = true;
        networking.jool.nat64.default = { };
      };
    })
  ];
})
