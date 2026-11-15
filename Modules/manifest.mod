{
  "format": "connect-modules",
  "v": 1,
  "generated": "2026-11-15T11:27:22.330Z",
  "modules": [
    {
      "file": "coding_agent.mod",
      "name": "Coding agent sidebar",
      "description": "A chat sidebar for coding agents. Uses the Claude Code CLI already installed on this PC, so your own Claude subscription does the work: no API key and nothing is sent anywhere by Connect.",
      "version": "0.3.0",
      "minApi": 3,
      "permissions": [
        "spawn",
        "ssh",
        "sshStream",
        "data"
      ],
      "sha256": "28b5d27374f5fe15853131d87e2e475948e665f51e2fb6e81f07df34bf31720f",
      "sig": "gqUCfrdkTbnfuPJN2fbqJEspgcpZ9O13kb8Jt3LDxxAtAgdJAqUAt/vDkhl/VTpRmovi9Z044VHX3/INUJLyCg==",
      "size": 39145
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
