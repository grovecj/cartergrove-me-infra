# Modules

Reusable building blocks called from root modules (`shared/`, `projects/*`).
A module has no backend and no provider configuration of its own: it uses the
caller's provider, and its resources are stored in the caller's state.

Planned:

- `project-database/`: a database + user for one project on the shared Postgres
  cluster (grovecj/cartergrove-me-infra#2).
