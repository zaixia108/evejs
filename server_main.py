"""EveJS multiplayer server launcher entrypoint."""

from evejs_server.app import run_app


def main() -> None:
    run_app()


if __name__ == "__main__":
    main()
