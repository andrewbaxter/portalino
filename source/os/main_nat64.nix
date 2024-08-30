{ spaghettinuum_config
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
    ./ipv6_pd.nix
    ({ pkgs, lib, ... }: {
      config = { };
    })
  ];
})
