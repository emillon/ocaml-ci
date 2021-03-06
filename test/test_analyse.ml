open Lwt.Infix

let () =
  Logs.(set_level (Some Info));
  Logs.set_reporter @@ Logs_fmt.reporter ()

module Analysis = struct
  include Ocaml_ci.Analyse.Analysis

  type ocamlformat_source = Ocaml_ci.Analyse_ocamlformat.source =
    | Opam of { version : string }
    | Vendored of { path : string }
  [@@deriving yojson, eq]

  let set_equality = Alcotest.(equal (slist string String.compare))

  (* Make the [t] type concrete from the observable fields for easier testing *)
  type t = {
    opam_files : string list; [@equal set_equality]
    is_duniverse : bool;
    ocamlformat_source : ocamlformat_source option;
  }
  [@@deriving eq, yojson]


  let of_dir ~job ~platforms ~solver_dir ~opam_repository_commit d =
    let solver = Ocaml_ci.Solver_pool.spawn_local ~solver_dir () in
    of_dir ~solver ~job ~platforms ~opam_repository_commit d
    |> Lwt_result.map (fun t ->
           {
             opam_files = opam_files t;
             is_duniverse = is_duniverse t;
             ocamlformat_source = ocamlformat_source t;
           })

  let t : t Alcotest.testable =
    Alcotest.testable (Fmt.using to_yojson Yojson.Safe.pretty_print) equal
end

let expect_test name ~project ~expected =
  Alcotest_lwt.test_case name `Quick (fun _switch () ->
      let ( // ) = Filename.concat in
      let root = Filename.current_dir_name // "_test" // name // "src" in
      let solver_dir = Filename.current_dir_name // "_test" // name in
      let repo = solver_dir // "opam-repository-builder" in
      let job =
        let label = "test_analyse-" ^ name in
        Current.Job.create
          ~switch:(Current.Switch.create ~label ())
          ~label ~config:(Current.Config.v ()) ()
      in
      Gen_project.instantiate ~root project;
      Gen_project.instantiate ~root:repo
        Gen_project.
          [
            folder "packages"
              [
                dummy_package "dune" [ "1.0" ];
                dummy_package "ocaml" [ "4.10.0"; "4.09.0" ];
                dummy_package "fmt" [ "1.0" ];
                dummy_package "logs" [ "1.0" ];
                dummy_package "alcotest" [ "1.0" ];
              ];
          ];
      let opam_repository = Fpath.v repo in
      Current.Process.exec ~job ~cancellable:true ~cwd:opam_repository
        ("", [| "git"; "init" |])
      >|= Result.get_ok
      >>= fun () ->
      Current.Process.exec ~job ~cancellable:true ~cwd:opam_repository
        ("", [| "git"; "add"; "." |])
      >|= Result.get_ok
      >>= fun () ->
      Current.Process.exec ~job ~cancellable:true ~cwd:opam_repository
        ("", [| "git"; "commit"; "-m"; "init" |])
      >|= Result.get_ok
      >>= fun () ->
      Current.Process.check_output ~job ~cancellable:true ~cwd:opam_repository
        ("", [| "git"; "rev-parse"; "HEAD" |])
      >|= Result.get_ok
      >>= fun hash ->
      Current.Process.exec ~job ~cancellable:true ~cwd:(Fpath.v solver_dir)
        ("", [| "git"; "clone"; "--bare"; "opam-repository-builder"; "opam-repository" |])
      >|= Result.get_ok
      >>= fun () ->
      let opam_repository_commit =
        Current_git.Commit_id.v
          ~repo:"opam-repository"
          ~hash:(String.trim hash)
          ~gref:"master"
      in
      Analysis.of_dir ~job ~platforms:Test_platforms.v ~solver_dir ~opam_repository_commit
        (Fpath.v root)
      >|= (function
            | Ok o -> o
            | Error (`Msg e) ->
                let path =
                  Current.Job.(log_path (id job))
                  |> Result.get_ok |> Fpath.to_string
                in
                let ch = open_in path in
                let len = in_channel_length ch in
                let log = really_input_string ch len in
                close_in ch;
                Printf.printf "Log:\n%s\n%!" log;
                Alcotest.failf "Analysis stage failed: %s" e)
      >|= Alcotest.(check Analysis.t) name expected)

(* example duniverse containing a single package *)
let duniverse =
  let open Gen_project in
  Folder
    ( "duniverse",
      [ Folder ("alcotest.0.8.5", [ File ("alcotest.opam", opam) ]) ] )

let test_simple =
  let project =
    let open Gen_project in
    [
      File ("example.opam", opam);
      File (".ocamlformat", ocamlformat ~version:"0.12");
    ]
  in
  let expected =
    let open Analysis in
    {
      opam_files = [ "example.opam" ];
      is_duniverse = false;
      ocamlformat_source = Some (Opam { version = "0.12" });
    }
  in
  expect_test "simple" ~project ~expected

let test_multiple_opam =
  let project =
    let open Gen_project in
    [
      File ("example.opam", opam);
      File ("example-foo.opam", opam);
      File ("example-bar.opam", opam);
      Folder
        ( "test",
          [
            (* .opam files not in the top-level of the project should be ignored *)
            File ("ignored.opam", opam);
            (* vendored duniverse should not be attributed to the project
               (including internal .opam files) *)
            Folder ("vendored", [ duniverse ]);
          ] );
    ]
  in
  let expected =
    let open Analysis in
    {
      opam_files = [ "example.opam"; "example-foo.opam"; "example-bar.opam" ];
      is_duniverse = false;
      ocamlformat_source = None;
    }
  in
  expect_test "multiple_opam" ~project ~expected

let test_duniverse =
  let project =
    let open Gen_project in
    [ File ("dune-get", dune_get); File ("example.opam", opam); duniverse ]
  in
  let expected =
    let open Analysis in
    {
      opam_files = [ "example.opam"; "duniverse/alcotest.0.8.5/alcotest.opam" ];
      is_duniverse = true;
      ocamlformat_source = None;
    }
  in
  expect_test "duniverse" ~project ~expected

let test_ocamlformat_vendored =
  let project =
    let open Gen_project in
    [
      File ("dune-get", dune_get);
      File ("example.opam", opam);
      (* This file is not parsed if ocamlformat is vendored *)
      File (".ocamlformat", empty_file);
      Folder
        ( "duniverse",
          [ Folder ("ocamlformat", [ File ("ocamlformat.opam", opam) ]) ] );
    ]
  in
  let expected =
    let open Analysis in
    {
      opam_files = [ "example.opam"; "duniverse/ocamlformat/ocamlformat.opam" ];
      is_duniverse = true;
      ocamlformat_source = Some (Vendored { path = "duniverse/ocamlformat" });
    }
  in
  expect_test "ocamlformat_vendored" ~project ~expected

let test_ocamlformat_self =
  let project =
    let open Gen_project in
    [ File ("ocamlformat.opam", opam); File (".ocamlformat", empty_file) ]
  in
  let expected =
    let open Analysis in
    {
      opam_files = [ "ocamlformat.opam" ];
      is_duniverse = false;
      ocamlformat_source = Some (Vendored { path = "." });
    }
  in
  expect_test "ocamlformat_self" ~project ~expected

let tests =
  [
    test_simple;
    test_multiple_opam;
    test_duniverse;
    test_ocamlformat_vendored;
    test_ocamlformat_self;
  ]
