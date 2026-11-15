{
  "format": "connect-modules",
  "v": 1,
  "generated": "2026-11-15T13:00:26.276Z",
  "modules": [
    {
      "file": "coding_agent.mod",
      "name": "Coding agent sidebar",
      "description": "A chat sidebar for coding agents. Uses the Claude Code CLI already installed on this PC, so your own Claude subscription does the work: no API key and nothing is sent anywhere by Connect.",
      "version": "0.4.0",
      "minApi": 3,
      "permissions": [
        "spawn",
        "ssh",
        "sshStream",
        "data"
      ],
      "sha256": "de8d249353e8a9b87c46cd4a661c6a7e619a384a826454c6751c37886ca14acc",
      "sig": "4tjEkPnE1GfrpfqeY8EaGCrexePcMcWbex8jKGTklFqJNUdCpjisI1doFhDOhwqBD26Du6xpTvJKTkwA9Zj2CQ==",
      "size": 43871
    },
    {
      "file": "docker_helper.mod",
      "name": "Docker helper",
      "description": "A Docker sidebar for your SSH servers: docker compose stacks (found by scanning for compose files and docker ps), containers, networks and volumes, live CPU / memory / network graphs, start / stop / restart, exec into a container, live log tail and a compose file editor. Works over your saved SSH logins through the docker CLI on the server: no socket exposed, nothing to install on the server.",
      "version": "0.1.0",
      "minApi": 3,
      "permissions": [
        "ssh",
        "sshStream",
        "data"
      ],
      "sha256": "4bf15346436472c5d31119a4e099ab10e2f7fe6a8c44b4185bf05f53dfbd209d",
      "sig": "PTzBJRApZnB8gWYe7GYEF0GYBfiKZ9+JYn3cVchkaH8ENi9nueBJM4RAaWqnWkVT/l09R925eABJtJehBLN9AA==",
      "size": 73574
    },
    {
      "file": "game_panel.mod",
      "name": "Game Panel Helper",
      "description": "Allows for management of game servers in a Pterodactyl-compatible panel.",
      "version": "1.1.2",
      "minApi": 1,
      "permissions": [],
      "sha256": "e3d014670e657553844e60ec138ca14b06ff559bb8738defe8329e0b055126c1",
      "sig": "bv/HSXCtLXz1QAsOnGMpHbMmHO2cMlZ8l/oSAfvk90NEZGFsy69R4y2oTYPOqNXptVpebLK8R5ag43gkMeidBA==",
      "size": 41546
    },
    {
      "file": "sync_server.mod",
      "name": "Sync server",
      "description": "Keep several PCs in sync through your own SSH server: servers, macros, notes, runbooks, IPMI entries, settings and trusted host keys. Encrypted before upload; the server only needs Python 3.",
      "version": "1.0.0",
      "minApi": 2,
      "permissions": [
        "ssh",
        "data"
      ],
      "sha256": "fe7e996d555c05334f85a619a3e588414e035426b89f408cba898598a2cea869",
      "sig": "5xL0ybv9rN498UYiOj9j0ms5GQNe/DLI6uELv4HEussz59I/ZhsS3Xe1hgNQ2rDEQMoB97+kHr1Bdw/LmL0zDg==",
      "size": 32883
    }
  ]
}
