{
  description = "A flake for lem";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      perSystem = {pkgs, ...}: let
        # --- Setup & Helpers ---
        lisp = pkgs.sbcl;

        # Release metadata comes from the checkout instead of being hard-coded:
        # lem.asd is the source of truth for the base version, and the flake
        # supplies the git revision used to stamp images and the app bundle.
        baseVersion = let
          m = builtins.match ''.*\(defsystem "lem"[[:space:]]+:version "([^"]+)".*'' (builtins.readFile ./lem.asd);
        in
          if m != null
          then builtins.head m
          else "2.3.0";

        gitRev = inputs.self.shortRev or inputs.self.dirtyShortRev or null;
        lispGitRev =
          if gitRev != null
          then ''"${gitRev}"''
          else "nil";
        lemVersion =
          if gitRev != null
          then "${baseVersion}-unstable-${gitRev}"
          else "${baseVersion}-unstable";

        # Helper to generate the Lisp build script used by all variants
        mkBuildScript = {entryPoint ? "lem:main", extraInit ? ""}:
          pkgs.writeText "build-lem.lisp" ''
            (defpackage :nix-cl-user (:use :cl))
            (in-package :nix-cl-user)

            ;; Load ASDF
            (load "${lem-base.asdfFasl}/asdf.${lem-base.faslExt}")
            (asdf:initialize-output-translations '(:output-translations :disable-cache :inherit-configuration))
            ;; Keep the source-registry scan out of local build artifacts. This
            ;; matters when a checkout carries direnv, qlot or vendored trees:
            ;; they are not systems and only slow the scan down.
            (dolist (dir '(".direnv" "result" ".qlot" "ocicl" "node_modules"))
              (pushnew dir asdf/source-registry:*default-source-registry-exclusions* :test #'equal))

            ;; Load Systems
            (mapcar #'asdf:load-system (uiop:split-string (uiop:getenv "systems")))

            ;; Stamp the flake revision into the image and refresh *VERSION*,
            ;; which src/lem.lisp computes at load time from the checkout.
            (when (find-package :lem-core)
              (setf (symbol-value (find-symbol "*GIT-REVISION*" :lem-core)) ${lispGitRev}
                    (symbol-value (find-symbol "*VERSION*" :lem-core))
                    (uiop:symbol-call :lem-core :get-version-string)))

            ;; Variant specific initialisation, baked into the image
            ${extraInit}

            ;; Dump Image
            (setf uiop:*image-entry-point* #'${entryPoint})
            (uiop:dump-image "lem" :executable t :compression t)
          '';

        # The webview frontend is rebuilt from its npm lockfile instead of
        # trusting whatever `dist/` happens to be checked in. `src` is scoped to
        # frontends/server/frontend so Lisp edits never invalidate the JS build,
        # and only `dist/` is installed because lem-server embeds that tree
        # verbatim (frontends/server/main.lisp, dump-files) as
        # frontend/dist/index.html + frontend/dist/assets/*.
        webviewFrontend = pkgs.buildNpmPackage {
          pname = "lem-webview-frontend";
          version = baseVersion;
          src = ./frontends/server/frontend;
          # `prefetch-npm-deps frontends/server/frontend/package-lock.json`
          # (fetcher version 1, the buildNpmPackage default).
          npmDepsHash = "sha256-eYPepJveNNw6YROqjGZr7446Mu4ABs+Is+g+WUuwwvU=";

          # Keep the platform font intent of the old per-variant dist patch, but
          # apply it to the frontend source before Vite bundles it instead of
          # guessing which quote form the minifier picked in the output.
          postPatch = ''
            substituteInPlace main.js \
              --replace-fail "fontName: 'Monospace'" \
                "fontName: '${if pkgs.stdenv.hostPlatform.isLinux then "DejaVu Sans Mono" else "Menlo"}'"
          '';

          installPhase = ''
            runHook preInstall
            test -f dist/index.html
            test -f dist/assets/index.js
            mkdir -p $out
            cp -r dist $out/dist
            runHook postInstall
          '';
        };

        # Swap the checked-in dist/ for the freshly built bundle before any
        # further patching so frontend source edits reach the image.
        # buildASDFSystem runs postPatch twice, so the copy starts from `rm -rf`
        # and is therefore idempotent, and the store copy's read-only modes are
        # widened for later dist substitutions.
        webviewDistPatch = ''
          rm -rf frontends/server/frontend/dist
          cp -r ${webviewFrontend}/dist frontends/server/frontend/dist
          chmod -R u+w frontends/server/frontend/dist
        '';

        sources = import ./_sources/generated.nix {
          inherit
            (pkgs)
            fetchgit
            fetchurl
            fetchFromGitHub
            dockerTools
            ;
        };

        # --- Core Lisp Dependencies ---

        micros = lisp.buildASDFSystem {
          inherit (sources.micros) pname src version;
          systems = ["micros"];
        };

        jsonrpc = lisp.buildASDFSystem {
          inherit (sources.jsonrpc) pname src version;
          systems = [
            "jsonrpc"
            "jsonrpc/transport/stdio"
            "jsonrpc/transport/tcp"
            "jsonrpc/transport/websocket"
            "jsonrpc/transport/local-domain-socket"
          ];
          lispLibs = with lisp.pkgs; [
            yason
            alexandria
            bordeaux-threads
            dissect
            chanl
            vom
            usocket
            trivial-timeout
            cl_plus_ssl
            quri
            fast-io
            trivial-utf-8
            websocket-driver
            clack
            clack-handler-hunchentoot
            event-emitter
            hunchentoot
          ];
        };

        async-process = let
          c-lib = pkgs.stdenv.mkDerivation {
            inherit (sources.async-process) pname src version;
            nativeBuildInputs = with pkgs; [
              libtool
              libffi.dev
              automake
              autoconf
              pkg-config
            ];
            buildPhase = "make PREFIX=$out";
          };
        in
          lisp.buildASDFSystem {
            inherit (sources.async-process) pname src version;
            systems = ["async-process"];
            lispLibs = [lisp.pkgs.cffi];
            nativeLibs = [c-lib];
            nativeBuildInputs = [pkgs.pkg-config];
          };

        lem-mailbox = lisp.buildASDFSystem {
          inherit (sources.lem-mailbox) pname src version;
          systems = ["lem-mailbox"];
          lispLibs = with lisp.pkgs; [
            bordeaux-threads
            bt-semaphore
            queues
            queues_dot_simple-cqueue
          ];
        };

        # --- Tree-sitter Support ---

        # Use local tree-sitter-cl if available, otherwise use nvfetcher source
        tree-sitter-cl-src = let
          localPath = /home/user/lem-project/tree-sitter-cl;
        in
          if builtins.pathExists localPath
          then localPath
          else sources.tree-sitter-cl.src;

        # C wrapper library for tree-sitter (handles by-value struct returns)
        ts-wrapper = pkgs.stdenv.mkDerivation {
          pname = "ts-wrapper";
          version = "0.1.0";
          src = "${tree-sitter-cl-src}/c-wrapper";
          buildInputs = [pkgs.tree-sitter];
          buildPhase = let
            ext =
              if pkgs.stdenv.hostPlatform.isDarwin
              then "dylib"
              else "so";
          in ''
            $CC -shared -fPIC -o libts-wrapper.${ext} ts-wrapper.c \
              -I${pkgs.tree-sitter}/include \
              -L${pkgs.tree-sitter}/lib \
              -ltree-sitter
          '';
          installPhase = let
            ext =
              if pkgs.stdenv.hostPlatform.isDarwin
              then "dylib"
              else "so";
          in ''
            mkdir -p $out/lib
            cp libts-wrapper.${ext} $out/lib/
          '';
        };

        # lem-terminal native helper (terminal.so), compiled from
        # extensions/terminal/terminal.c against libvterm. Dynamically linked:
        # the Nix stdenv records an RPATH to the libvterm store path, so it
        # resolves at runtime without any bundling or relinking. lem-terminal/
        # ffi.lisp loads it by the literal name "terminal.so" (even on macOS),
        # so the output keeps the .so suffix on both platforms.
        #
        # Uses libvterm-neovim, which is Leonerd's modern libvterm that
        # terminal.c targets. Plain pkgs.libvterm is a different, abandoned
        # glib/curses-based library with an incompatible API. libvterm-neovim
        # is Linux-only in nixpkgs, hence the Linux gate at the use sites, so
        # -lutil (forkpty) is unconditional here.
        terminal-so = pkgs.stdenv.mkDerivation {
          pname = "lem-terminal-so";
          version = "0.1.0";
          src = ./extensions/terminal;
          buildInputs = [pkgs.libvterm-neovim];
          buildPhase = ''
            $CC -shared -fPIC -o terminal.so terminal.c \
              -I${pkgs.libvterm-neovim}/include \
              -L${pkgs.libvterm-neovim}/lib -lvterm \
              -lutil
          '';
          installPhase = ''
            mkdir -p $out/lib
            cp terminal.so $out/lib/
          '';
        };

        # tree-sitter-cl Lisp bindings (from github.com/lem-project/tree-sitter-cl)
        tree-sitter-cl = lisp.buildASDFSystem {
          pname = "tree-sitter-cl";
          version = sources.tree-sitter-cl.version;
          src = tree-sitter-cl-src;
          systems = ["tree-sitter-cl"];
          lispLibs = with lisp.pkgs; [
            cffi
            alexandria
            trivial-garbage
          ];
          nativeLibs = [
            pkgs.tree-sitter
            ts-wrapper
          ];
        };

        # Tree-sitter language grammars
        tree-sitter-grammars = {
          json = pkgs.tree-sitter-grammars.tree-sitter-json;
          markdown = pkgs.tree-sitter-grammars.tree-sitter-markdown;
          yaml = pkgs.tree-sitter-grammars.tree-sitter-yaml;
          nix = pkgs.tree-sitter-grammars.tree-sitter-nix;
          # Languages for Living Canvas multi-language support
          python = pkgs.tree-sitter-grammars.tree-sitter-python;
          javascript = pkgs.tree-sitter-grammars.tree-sitter-javascript;
          typescript = pkgs.tree-sitter-grammars.tree-sitter-typescript;
          go = pkgs.tree-sitter-grammars.tree-sitter-go;
          perl = pkgs.tree-sitter-grammars.tree-sitter-perl;
          # Clojure support
          clojure = pkgs.tree-sitter-grammars.tree-sitter-clojure;
        };

        # --- Webview Specific Dependencies ---

        c-webview = pkgs.stdenv.mkDerivation {
          pname = "c-webview";
          version = "unstable";
          src = sources.webview.src;
          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
          ];
          buildInputs =
            if pkgs.stdenv.hostPlatform.isLinux
            then [
              pkgs.webkitgtk_4_1
              pkgs.webkitgtk_6_0
              pkgs.gtk3
            ]
            else [];

          # Use FETCHCONTENT to use pre-fetched source instead of network
          configurePhase = ''
            runHook preConfigure
            cmake -G Ninja -B build -S c \
              -DCMAKE_BUILD_TYPE=Release \
              -DFETCHCONTENT_SOURCE_DIR_WEBVIEW=${sources.webview-upstream.src}
            runHook postConfigure
          '';
          buildPhase = "cmake --build build";
          installPhase = let
            suffix =
              if pkgs.stdenv.hostPlatform.isLinux
              then "so"
              else "dylib";
          in ''
            mkdir -p $out/lib
            cp build/lib/libexample.${suffix} $out/lib/libwebview.${suffix}
          '';
        };

        cl-webview = lisp.buildASDFSystem {
          inherit (sources.webview) pname src version;
          systems = ["webview"];
          lispLibs = with lisp.pkgs; [
            cffi
            float-features
          ];
          nativeLibs = [c-webview];
          postPatch = ''
            # Fix library loading path and name in the Lisp binding
            sed -i 's/(define-foreign-library (libwebview/(define-foreign-library libwebview/' webview.lisp
            sed -i '/:search-path/,/arm64"))))/d' webview.lisp
            sed -i 's/"libwebview\.so\.0\.12\.0"/"libwebview.so"/' webview.lisp
          '';
        };

        # --- Lem Core Definition ---

        # List of libraries common to all Lem frontends
        commonLispLibs = with lisp.pkgs; [
          micros
          async-process
          jsonrpc
          lem-mailbox
          tree-sitter-cl
          deploy
          iterate
          closer-mop
          trivia
          alexandria
          trivial-gray-streams
          trivial-types
          cl-ppcre
          cl-unicode
          inquisitor
          babel
          bordeaux-threads
          yason
          log4cl
          split-sequence
          str
          dexador
          cl-mustache
          esrap
          parse-number
          cl-package-locks
          trivial-utf-8
          swank
          _3bmd
          _3bmd-ext-code-blocks
          lisp-preprocessor
          trivial-ws
          trivial-open-browser
          frugal-uuid
          hunchentoot
          cl-template
        ];

        makeLemDesktopItem = { terminal }: pkgs.makeDesktopItem {
          name = "lem";
          desktopName = "Lem";
          comment = "Common Lisp editor/IDE with high expansibility";
          exec = "lem %F";
          mimeTypes = [
            "text/english"
            "text/plain"
            "text/x-makefile"
            "text/x-c++hdr"
            "text/x-c++src"
            "application/x-shellscript"
            "text/x-c"
            "text/x-c++"
          ];
          icon = "lem";
          terminal = terminal;
          type = "Application";
          categories = [
            "Development"
            "TextEditor"
          ];
        };

        # The base derivation that other variants inherit from
        lem-base = lisp.buildASDFSystem {
          pname = "lem-base";
          version = lemVersion;
          src = ./.;
          nativeBuildInputs = [pkgs.makeBinaryWrapper];
          lispLibs = commonLispLibs;

          postPatch = ''
            sed -i '1i(pushnew :nix-build *features*)' lem.asd
          '';

          buildScript = mkBuildScript {entryPoint = "lem:main";};

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install lem $out/bin
            wrapProgram $out/bin/lem \
              --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH" \
              --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"
            runHook postInstall
          '';
        };

        # 1. Ncurses Variant
        lem-ncurses = lem-base.overrideLispAttrs (o: {
          pname = "lem-ncurses";
          meta.mainProgram = "lem";
          systems = [
            "lem-ncurses"
            "tree-sitter-cl"
            "lem-tree-sitter"
          ];
          lispLibs =
            o.lispLibs
            ++ (with lisp.pkgs; [
              cl-charms
              cl-setlocale
            ]);
          nativeLibs =
            [
              pkgs.ncurses
              pkgs.tree-sitter
              ts-wrapper
            ]
            # libvterm is Linux-only in nixpkgs, so terminal-so (and thus the
            # terminal extension) is only available on Linux Nix builds.
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [terminal-so];
          # Add tree-sitter grammar paths (grammars don't have lib/ subdir)
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install lem $out/bin
            wrapProgram $out/bin/lem \
              --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${tree-sitter-grammars.json}:${tree-sitter-grammars.markdown}:${tree-sitter-grammars.yaml}:${tree-sitter-grammars.nix}:${tree-sitter-grammars.python}:${tree-sitter-grammars.javascript}:${tree-sitter-grammars.typescript}:${tree-sitter-grammars.go}:${tree-sitter-grammars.perl}:${tree-sitter-grammars.clojure}" \
              --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"

            mkdir -p $out/share/applications
            cp ${makeLemDesktopItem {terminal = true;}}/share/applications/* $out/share/applications
            mkdir -p $out/share/icons/hicolor/256x256/apps
            cp ${./resources/lem.png} $out/share/icons/hicolor/256x256/apps/lem.png

            runHook postInstall
          '';
        });

        # 2. SDL2 Variant
        lem-sdl2 = lem-base.overrideLispAttrs (o: {
          pname = "lem-sdl2";
          meta.mainProgram = "lem";
          systems = [
            "lem-sdl2"
            "tree-sitter-cl"
            "lem-tree-sitter"
          ];
          lispLibs =
            o.lispLibs
            ++ (with lisp.pkgs; [
              sdl2
              sdl2-ttf
              sdl2-image
              trivial-main-thread
            ]);
          nativeLibs =
            (with pkgs; [
              SDL2
              SDL2_ttf
              SDL2_image
              tree-sitter
              ts-wrapper
            ])
            # libvterm is Linux-only in nixpkgs (see lem-ncurses).
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [terminal-so];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install lem $out/bin
            wrapProgram $out/bin/lem \
              --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${tree-sitter-grammars.json}:${tree-sitter-grammars.markdown}:${tree-sitter-grammars.yaml}:${tree-sitter-grammars.nix}:${tree-sitter-grammars.python}:${tree-sitter-grammars.javascript}:${tree-sitter-grammars.typescript}:${tree-sitter-grammars.go}:${tree-sitter-grammars.perl}:${tree-sitter-grammars.clojure}" \
              --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"

            mkdir -p $out/share/applications
            cp ${makeLemDesktopItem {terminal = false;}}/share/applications/* $out/share/applications
            mkdir -p $out/share/icons/hicolor/256x256/apps
            cp ${./resources/lem.png} $out/share/icons/hicolor/256x256/apps/lem.png

            runHook postInstall
          '';
        });

        # 3. Webview Variant
        lem-webview = lem-base.overrideLispAttrs (o: {
          pname = "lem-webview";
          meta.mainProgram = "lem";
          systems = [
            "lem-webview"
            "tree-sitter-cl"
            "lem-tree-sitter"
          ];

          # Use the specific webview entry point
          buildScript = mkBuildScript {entryPoint = "lem-webview:main";};

          lispLibs =
            o.lispLibs
            ++ [cl-webview]
            ++ (with lisp.pkgs; [
              float-features
              command-line-arguments
            ]);

          nativeLibs =
            if pkgs.stdenv.hostPlatform.isLinux
            then [
              pkgs.webkitgtk_4_1
              pkgs.webkitgtk_6_0
              pkgs.gtk3
              pkgs.stdenv.cc.cc.lib
              c-webview
              pkgs.tree-sitter
              ts-wrapper
              terminal-so
            ]
            else [
              pkgs.stdenv.cc.cc.lib
              c-webview
              pkgs.tree-sitter
              ts-wrapper
            ];

          # The bundle is rebuilt from source (webviewFrontend), which also
          # applies the platform font while bundling, so the old post-hoc dist
          # substitution is no longer needed here.
          postPatch = (o.postPatch or "") + webviewDistPatch;

          postInstall =
            if pkgs.stdenv.hostPlatform.isLinux
            then ''
              wrapProgram $out/bin/lem \
                --set FONTCONFIG_FILE "${pkgs.makeFontsConf {fontDirectories = [pkgs.dejavu_fonts];}}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
                --prefix LD_LIBRARY_PATH : "${tree-sitter-grammars.json}:${tree-sitter-grammars.markdown}:${tree-sitter-grammars.yaml}:${tree-sitter-grammars.nix}:${tree-sitter-grammars.python}:${tree-sitter-grammars.javascript}:${tree-sitter-grammars.typescript}:${tree-sitter-grammars.go}:${tree-sitter-grammars.perl}:${tree-sitter-grammars.clojure}"

              mkdir -p $out/share/applications
              cp ${makeLemDesktopItem {terminal = false;}}/share/applications/* $out/share/applications
              mkdir -p $out/share/icons/hicolor/256x256/apps
              cp ${./resources/lem.png} $out/share/icons/hicolor/256x256/apps/lem.png

            ''
            else ''
              wrapProgram $out/bin/lem \
                --prefix LD_LIBRARY_PATH : "${tree-sitter-grammars.json}:${tree-sitter-grammars.markdown}:${tree-sitter-grammars.yaml}:${tree-sitter-grammars.nix}:${tree-sitter-grammars.python}:${tree-sitter-grammars.javascript}:${tree-sitter-grammars.typescript}:${tree-sitter-grammars.go}:${tree-sitter-grammars.perl}:${tree-sitter-grammars.clojure}"
            '';
        });

        # Grammar roots for the personal wrapper. Derived here rather than
        # reusing the long per-variant lists above so this variant stays
        # self-contained.
        personalGrammarSearchPath =
          pkgs.lib.concatStringsSep ":" (builtins.attrValues tree-sitter-grammars);

        # 4. Personal Variant: a single image carrying both the webview and the
        # ncurses frontends, plus the extras used day to day. On Darwin it is
        # shipped as a normal .app bundle (WebKit only works in a bundled
        # executable, and Finder launches it from "/") and the same binary is
        # exposed as bin/lem for terminal use.
        lem-personal = lem-base.overrideLispAttrs (o: {
          pname = "lem-personal";
          meta.mainProgram = "lem";
          systems = [
            "lem-webview"
            "lem-ncurses"
            "lem-encodings"
            "lem-coalton-mode"
            "tree-sitter-cl"
            "lem-tree-sitter"
          ];

          buildScript = mkBuildScript {
            entryPoint = "lem:main";
            # The hook is registered with weight -1 so it runs after lem-core's
            # macOS hook from src/macosx.lisp, which replaces PATH outright.
            extraInit = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
              ;; lem-personal: put host tools (nix profile, homebrew, ...) on
              ;; PATH and start in $HOME when launched from the filesystem root.
              (lem-core:add-hook
               lem-core:*after-init-hook*
               (lambda ()
                 (flet ((directory-name (dir)
                          (let* ((name (if (pathnamep dir)
                                           (uiop:native-namestring dir)
                                           dir))
                                 (trimmed (string-right-trim "/" name)))
                            ;; exec-path returns pathnames with trailing slashes;
                            ;; "/" itself must survive the trim.
                            (if (string= trimmed "") name trimmed))))
                   (let* ((path (uiop:getenv "PATH"))
                          (user (uiop:getenv "USER"))
                          (dirs
                            (remove-duplicates
                             (loop :for dir
                                   :in (append
                                        (list (format nil "~A/.local/bin" (uiop:getenv "HOME"))
                                              (format nil "/etc/profiles/per-user/~A/bin" user)
                                              "/run/current-system/sw/bin"
                                              "/nix/var/nix/profiles/default/bin")
                                        (lem-core:exec-path))
                                   :for name = (and dir (directory-name dir))
                                   :when (and name (uiop:directory-exists-p name))
                                     :collect name)
                             :from-end t :test #'string=)))
                     (setf (uiop:getenv "PATH")
                           (format nil "~{~A~^:~}"
                                   (if (and path (string/= path ""))
                                       (append dirs (list path))
                                       dirs)))))
                 (when (uiop:pathname-equal (uiop:getcwd) #P"/")
                   (setf *default-pathname-defaults* (user-homedir-pathname))
                   (uiop:chdir (user-homedir-pathname))))
               -1);
            '';
          };

          nativeBuildInputs =
            (o.nativeBuildInputs or [])
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [pkgs.libicns];

          lispLibs =
            o.lispLibs
            ++ [cl-webview]
            ++ (with lisp.pkgs; [
              float-features
              command-line-arguments
              cl-charms
              cl-setlocale
            ]);

          nativeLibs =
            [
              pkgs.stdenv.cc.cc.lib
              pkgs.ncurses
              c-webview
              pkgs.tree-sitter
              ts-wrapper
              terminal-so
            ]
            # WebKit/GTK are Linux-only; the terminal helper is shared.
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.webkitgtk_4_1
              pkgs.webkitgtk_6_0
              pkgs.gtk3
            ];

          # The webview bundle is rebuilt from source (webviewFrontend), which
          # also applies the platform font while bundling; the checked-in dist
          # must not shadow it.
          postPatch = (o.postPatch or "") + webviewDistPatch;

          # Overriding installPhase (rather than using postInstall) keeps the
          # macOS bundle from being wrapped a second time by the base variant.
          installPhase =
            if pkgs.stdenv.hostPlatform.isDarwin
            then ''
              runHook preInstall

              app="$out/Applications/Lem.app"
              mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/bin"
              install -m 755 lem "$app/Contents/MacOS/Lem"
              png2icns "$app/Contents/Resources/Lem.icns" ${./resources/lem.png}
              cp ${./resources/lem.png} "$app/Contents/Resources/Lem.png"

              cat > "$app/Contents/Info.plist" <<EOF
              <?xml version="1.0" encoding="UTF-8"?>
              <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
              <plist version="1.0">
              <dict>
                <key>CFBundleName</key>
                <string>Lem</string>
                <key>CFBundleDisplayName</key>
                <string>Lem</string>
                <key>CFBundleExecutable</key>
                <string>Lem</string>
                <key>CFBundleIconFile</key>
                <string>Lem</string>
                <key>CFBundleIdentifier</key>
                <string>com.lem-project.lem</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleVersion</key>
                <string>${baseVersion}</string>
                <key>CFBundleShortVersionString</key>
                <string>${baseVersion}</string>${pkgs.lib.optionalString (gitRev != null) ''

                <key>LemGitRevision</key>
                <string>${gitRev}</string>''}
                <key>NSHighResolutionCapable</key>
                <true/>
              </dict>
              </plist>
              EOF

              wrapProgram "$app/Contents/MacOS/Lem" \
                --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${personalGrammarSearchPath}" \
                --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH" \
                --set-default LEM_BUILD_SRC "$src"

              ln -s ../Applications/Lem.app/Contents/MacOS/Lem "$out/bin/lem"

              runHook postInstall
            ''
            else ''
              runHook preInstall

              mkdir -p "$out/bin"
              install -m 755 lem "$out/bin/lem"
              wrapProgram "$out/bin/lem" \
                --set FONTCONFIG_FILE "${pkgs.makeFontsConf {fontDirectories = [pkgs.dejavu_fonts];}}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
                --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${personalGrammarSearchPath}" \
                --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH" \
                --set-default LEM_BUILD_SRC "$src"

              mkdir -p "$out/share/applications"
              cp ${makeLemDesktopItem {terminal = false;}}/share/applications/* "$out/share/applications"
              mkdir -p "$out/share/icons/hicolor/256x256/apps"
              cp ${./resources/lem.png} "$out/share/icons/hicolor/256x256/apps/lem.png"

              runHook postInstall
            '';
        });
      in {
        overlayAttrs = {
          inherit lem-ncurses lem-sdl2 lem-webview lem-personal;
        };

        packages = {
          inherit lem-ncurses lem-sdl2 lem-webview lem-personal;
          default = lem-personal;
        };

        apps = {
          lem-ncurses = {
            type = "app";
            program = lem-ncurses;
          };
          lem-sdl2 = {
            type = "app";
            program = lem-sdl2;
          };
          lem-webview = {
            type = "app";
            program = lem-webview;
          };
          lem-personal = {
            type = "app";
            program = lem-personal;
          };
          default = {
            type = "app";
            program = lem-personal;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs;
            [
              # Lisp development
              sbcl
              sbclPackages.qlot-cli

              # Build tools
              gnumake
              pkg-config

              # Node.js for frontend development
              nodejs_22

              # Native libraries for frontends
              ncurses
              SDL2
              SDL2_ttf
              SDL2_image

              # SSL/TLS support
              openssl

              # Tree-sitter support
              tree-sitter
              pkgs.tree-sitter-grammars.tree-sitter-json
              pkgs.tree-sitter-grammars.tree-sitter-markdown
              pkgs.tree-sitter-grammars.tree-sitter-yaml
              pkgs.tree-sitter-grammars.tree-sitter-nix
              pkgs.tree-sitter-grammars.tree-sitter-python
              pkgs.tree-sitter-grammars.tree-sitter-javascript
              pkgs.tree-sitter-grammars.tree-sitter-typescript
              pkgs.tree-sitter-grammars.tree-sitter-go
              pkgs.tree-sitter-grammars.tree-sitter-perl
              pkgs.tree-sitter-grammars.tree-sitter-clojure

              # Perl Language Server
              pkgs.perl5Packages.PLS # provides 'pls' command (used by lem-perl-mode)

              # Clojure development
              clojure
              clojure-lsp
              leiningen
              babashka

              # Code formatting
              nixfmt-rfc-style

              # Development tools
              direnv
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              # Linux-specific dependencies for webview frontend
              webkitgtk_4_1
              gtk3
            ];

          # Set up library paths for native dependencies
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
            [
              pkgs.ncurses
              pkgs.SDL2
              pkgs.SDL2_ttf
              pkgs.SDL2_image
              pkgs.openssl
              pkgs.tree-sitter
              ts-wrapper
              pkgs.tree-sitter-grammars.tree-sitter-json
              pkgs.tree-sitter-grammars.tree-sitter-markdown
              pkgs.tree-sitter-grammars.tree-sitter-yaml
              pkgs.tree-sitter-grammars.tree-sitter-nix
              pkgs.tree-sitter-grammars.tree-sitter-python
              pkgs.tree-sitter-grammars.tree-sitter-javascript
              pkgs.tree-sitter-grammars.tree-sitter-typescript
              pkgs.tree-sitter-grammars.tree-sitter-go
              pkgs.tree-sitter-grammars.tree-sitter-perl
              pkgs.tree-sitter-grammars.tree-sitter-clojure
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.webkitgtk_4_1
              pkgs.gtk3
              pkgs.glib
              pkgs.stdenv.cc.cc.lib
            ]
          );

          shellHook = ''
            # Prioritize local tree-sitter-cl c-wrapper for development
            if [ -f "$HOME/lem-project/tree-sitter-cl/c-wrapper/libts-wrapper.so" ]; then
              export LD_LIBRARY_PATH="$HOME/lem-project/tree-sitter-cl/c-wrapper:$LD_LIBRARY_PATH"
            fi
            echo "Lem development environment"
            echo "  SBCL: $(sbcl --version)"
            echo "  qlot: $(qlot --version 2>/dev/null || echo 'available')"
            echo "  clojure-lsp: $(clojure-lsp --version 2>/dev/null | head -1 || echo 'available')"
            echo ""
            echo "Quick start:"
            echo "  qlot install    # Install dependencies"
            echo "  make ncurses    # Build terminal version"
            echo "  make sdl2       # Build GUI version"
            echo ""
            echo "Clojure tools:"
            echo "  clojure-lsp     # Clojure Language Server"
            echo "  clojure / clj   # Clojure CLI"
            echo "  lein            # Leiningen build tool"
            echo "  bb              # Babashka scripting"
          '';
        };
      };
    };
}
