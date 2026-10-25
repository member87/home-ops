terraform {
  required_version = ">= 1.6"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.14"
    }
  }
  # State lives in the Terrakube workspace "b2-backup" (organization homeops);
  # runs execute remotely. Never commit *.tfstate (gitignored).
}
