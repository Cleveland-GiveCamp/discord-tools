{
  description = "Discord role management tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        duplicate-role = pkgs.writeShellApplication {
          name = "duplicate-role";
          runtimeInputs = [ pkgs.curl pkgs.jq ];
          text = builtins.readFile ./duplicate-role.sh;
        };

        set-event-folder-permissions = pkgs.writeShellApplication {
          name = "set-event-folder-permissions";
          runtimeInputs = [ pkgs.curl pkgs.jq ];
          text = builtins.readFile ./set-event-folder-permissions.sh;
        };

        set-organizer-folder-permissions = pkgs.writeShellApplication {
          name = "set-organizer-folder-permissions";
          runtimeInputs = [ pkgs.curl pkgs.jq ];
          text = builtins.readFile ./set-organizer-folder-permissions.sh;
        };

        find-duplicate-year-roles = pkgs.writeShellApplication {
          name = "find-duplicate-year-roles";
          runtimeInputs = [ pkgs.curl pkgs.jq ];
          text = builtins.readFile ./find-duplicate-year-roles.sh;
        };
      in
      {
        packages = {
          inherit duplicate-role set-event-folder-permissions set-organizer-folder-permissions find-duplicate-year-roles;
          default = duplicate-role;
        };

        apps = {
          duplicate-role                   = flake-utils.lib.mkApp { drv = duplicate-role; };
          set-event-folder-permissions     = flake-utils.lib.mkApp { drv = set-event-folder-permissions; };
          set-organizer-folder-permissions = flake-utils.lib.mkApp { drv = set-organizer-folder-permissions; };
          find-duplicate-year-roles        = flake-utils.lib.mkApp { drv = find-duplicate-year-roles; };
          default = self.apps.${system}.duplicate-role;
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.curl pkgs.jq ];
        };
      });
}
