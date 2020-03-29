let
  all-devices =
    builtins.filter
      (d: builtins.pathExists (./. + "/devices/${d}/default.nix"))
      (builtins.attrNames (builtins.readDir ./devices))
  ;
in
{ mobile-nixos ? builtins.fetchGit ./.
# By default, builds all devices.
, devices ? all-devices
# By default, assume we eval only for currentSystem
, systems ? [ builtins.currentSystem ]
# nixpkgs is also an input, used as `<nixpkgs>` in the system configuration.
}:

let
  # We require some `lib` stuff in here.
  # Pick a lib from the ambient <nixpkgs>.
  inherit (import <nixpkgs> {}) lib releaseTools;

  # Given a device compatible with `default.nix`, eval.
  evalFor = evalWithConfiguration {};
  evalWithConfiguration = additionalConfiguration: device:
    import ./. { inherit device additionalConfiguration; }
  ;

  # Systems we should eval for, per host system.
  # Non-native will be assumed cross.
  shouldEvalOn = {
    x86_64-linux = [
      "armv7l-linux"
      "aarch64-linux"
      "x86_64-linux"
    ];
    aarch64-linux = [
      "aarch64-linux"
    ];
    armv7l-linux = [
      "armv7l-linux"
    ];
  };

  # Shortcuts from a simple system name to the structure required for
  # localSystem and crossSystem
  knownSystems = {
    x86_64-linux  = lib.systems.examples.gnu64;
    aarch64-linux = lib.systems.examples.aarch64-multiplatform;
    armv7l-linux  = lib.systems.examples.armv7l-hf-multiplatform;
  };

  # Given an evaluated "device", filters `pkgs` down to only our packages
  # unique to the overaly.
  # Also removes some non-packages from the overlay.
  overlayForEval =
    let
      # Trick the overlay in giving us its attributes.
      # Using the values is likely to fail. Thank lazyness!
      overlay = import ./overlay/overlay.nix {} {};
    in
    eval: 
    (lib.genAttrs (builtins.attrNames overlay) (name: eval.pkgs.${name})) //
    {
      # We only "monkey patch" over top of the main nixos one.
      xorg = {
        xf86videofbdev = eval.pkgs.xorg.xf86videofbdev;
      };

      # lib-like attributes...
      # How should we handle these?
      imageBuilder = null;
      kernel-builder = null;
      kernel-builder-gcc49 = null;
      kernel-builder-gcc6 = null;

      # Also lib-like, but a "global" like attribute :/
      defaultKernelPatches = null;
    }
  ;

  # Given a system builds run on, this will return a set of further systems
  # this builds in, either native or cross.
  # The values are `overlayForEval` applied for the pair local/cross systems.
  evalForSystem = system:  builtins.listToAttrs
    (builtins.map (
      buildingForSystem:
      let
        # "device" name for the eval *and* key used for the set.
        name = if system == buildingForSystem then buildingForSystem else "${buildingForSystem}-cross";
        # "device" eval for our dummy device.
        eval = evalFor {
          special = true;
          inherit name;
          config = {
            mobile.system.type = "none";
            mobile.hardware.soc = {
              x86_64-linux = "generic-x86_64";
              aarch64-linux = "generic-aarch64";
              armv7l-linux = "generic-armv7l";
            }.${buildingForSystem};
            nixpkgs.localSystem = knownSystems.${system};
          };
        };
        overlay = overlayForEval eval;
      in {
        inherit name;
        value = overlay;
      }) shouldEvalOn.${system}
    )
  ;

  # `device` here is indexed by the system it's being built on first.
  # FIXME: can we better filter this?
  device = lib.genAttrs devices (device:
    lib.genAttrs systems (system:
      (evalWithConfiguration {
        nixpkgs.localSystem = knownSystems.${system};
      } device).build.default
    )
  );
in
{
  inherit device;

  # Overlays build native, and cross, according to shouldEvalOn
  overlay = lib.genAttrs systems (system:
    (evalForSystem system)
  );

  tested = let
    hasSystem = name: lib.lists.any (el: el == name) systems;

    constituents =
      lib.optionals (hasSystem "x86_64-linux") [
        device.qemu-x86_64.x86_64-linux              # VM
        # Cross builds
        device.asus-z00t.x86_64-linux                # Android
        device.asus-dumo.x86_64-linux                # Depthcharge
      ]
      ++ lib.optionals (hasSystem "aarch64-linux") [
        device.asus-z00t.aarch64-linux               # Android
        device.asus-dumo.aarch64-linux               # Depthcharge
      ];
  in
  releaseTools.aggregate {
    name = "mobile-nixos-tested";
    inherit constituents;
    meta = {
      description = "Representative subset of devices that have to succeed.";
    };
  };
}
