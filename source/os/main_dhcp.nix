{ spaghettinuum_config
, override_mtu ? null
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
    (import ./ipv6_bridge.nix { override_mtu = override_mtu; })
    ({ pkgs, lib, ... }: {
      config = {
        systemd.network.networks.eth0 = {
          DHCP = "yes";
        };
        networking.jool.enable = true;
        networking.jool.nat64.default = { };
      };
    })
  ];
})
