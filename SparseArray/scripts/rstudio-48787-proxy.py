#!/usr/bin/env python3
"""Expose the remote-Docker RStudio service on the workspace host."""

import asyncio
import contextlib
import os
import socket


configured_listen_host = os.getenv("RSTUDIO_PROXY_LISTEN_HOST")
LISTEN_HOSTS = (
    (configured_listen_host,)
    if configured_listen_host
    else tuple(dict.fromkeys((
        "127.0.0.1",
        *socket.gethostbyname_ex(socket.gethostname())[2],
    )))
)
LISTEN_PORT = 48787
UPSTREAM_HOST = "docker"
UPSTREAM_PORT = 48787


async def relay(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
) -> None:
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(
            UPSTREAM_HOST,
            UPSTREAM_PORT,
        )
    except OSError:
        client_writer.close()
        await client_writer.wait_closed()
        return

    tasks = {
        asyncio.create_task(relay(client_reader, upstream_writer)),
        asyncio.create_task(relay(upstream_reader, client_writer)),
    }
    _done, pending = await asyncio.wait(
        tasks,
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    for writer in (client_writer, upstream_writer):
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def main() -> None:
    server = await asyncio.start_server(
        handle_client,
        LISTEN_HOSTS,
        LISTEN_PORT,
        reuse_address=True,
    )
    await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
