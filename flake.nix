{
  description = "Elixir Development Environment";

  inputs = {
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-24.05"; };
    flake-utils = { url = "github:numtide/flake-utils"; };
  };

  outputs = { self, nixpkgs, flake-utils }:
   flake-utils.lib.eachDefaultSystem (system:
      let
        inherit (pkgs.lib) optional optionals;
        pkgs = import nixpkgs { inherit system; };
      in
      with pkgs;
      {
        devShell = pkgs.mkShell {
          buildInputs = [
            elixir
          ] ;
        };
      });
}
