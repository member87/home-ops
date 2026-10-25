terraform {
  backend "remote" {
    hostname     = "terrakube-api.lab.jackhumes.com"
    organization = "homeops"
    workspaces {
      name = "b2-backup"
    }
  }
}
