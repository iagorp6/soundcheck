# Architecture

Three scripts, one service, two ways of running it. This document is the map;
the reasoning behind each decision lives in the comments of the file it
belongs to.

## The pieces

| File | Role |
|---|---|
| [`showtime.sh`](../showtime.sh) | Build a version, prove it healthy, put it on air |
| [`soundcheck.sh`](../soundcheck.sh) | Keep asking whether it is still healthy |
| [`encore.sh`](../encore.sh) | Put a known-good earlier version back |
| [`lib/common.sh`](../lib/common.sh) | Config, the two output channels, the event log |
| [`app/`](../app) | The Flask service being deployed |
| [`observability/`](../observability) | Prometheus, Grafana, Loki, Alertmanager, via Compose |
| [`k8s/`](../k8s) | The same story told with Kubernetes primitives |

## Docker mode: the blue-green deploy

The important property is where the failure is discovered. The candidate has
to prove itself on port 8081 while the old version is still answering on 8080,
so a bad build costs a build and nothing else.

```mermaid
flowchart TD
    start([./showtime.sh 1.2.0]) --> build[docker build]
    build --> tag["tag the live image as :previous<br/>append deploy_started to the event log"]
    tag --> cand["run the candidate on :8081<br/>old version still serving :8080"]
    cand --> probe{"curl -sf :8081/health<br/>up to 10 attempts"}

    probe -- "never healthy" --> scrap["remove the candidate<br/>log result=failure"]
    scrap --> safe([":8080 untouched<br/>exit 2, no rollback needed"])

    probe -- healthy --> cut["stop old, start the verified image on :8080"]
    cut --> verify{"curl -sf :8080/health"}
    verify -- healthy --> prune["prune to RETENTION_COUNT versions<br/>log result=success"]
    prune --> live([on air])

    verify -- unhealthy --> decide{--auto-rollback?}
    decide -- yes --> encore["exec ./encore.sh"]
    decide -- no --> human(["print the options<br/>exit 3, leave state alone"])
```

The two failure paths are deliberately different. A candidate that never comes
up is not an incident, because nothing was taken away from anyone. A failure
after the cutover is one, and it is the only place the automatic-versus-manual
rollback question actually arises.

## The rollback path

`encore.sh` reads the event log rather than trusting a single `:previous`
tag, which is what lets it go back more than one step and tell you in advance
what is reachable.

```mermaid
flowchart LR
    call([./encore.sh]) --> arg{version given?}
    arg -- "yes: 1.1.0" --> target[that version]
    arg -- no --> hist["read deploy_history.log<br/>newest successful deploy<br/>that is not the running one"]
    hist --> target
    target --> exists{image still on disk?}
    exists -- "no, pruned" --> show["show available targets<br/>exit 1, change nothing"]
    exists -- yes --> run["recreate the container from that tag"]
    run --> check{"curl -sf :8080/health"}
    check -- healthy --> done([back on air])
    check -- unhealthy --> esc(["the escape hatch failed<br/>look outside the app<br/>exit 2"])
```

## Kubernetes mode

Same three beats, handed to the orchestrator. The retry loop disappears
because `kubectl rollout status` blocks on the readiness probe, and the
blue-green dance disappears because `maxUnavailable: 0` already refuses to
remove an old Pod before a new one is Ready.

```mermaid
flowchart TD
    k([./showtime.sh 1.2.0 --k8s]) --> kb[docker build]
    kb --> load["kind load docker-image<br/>the node has its own image store"]
    load --> apply["kubectl apply: namespace, configmap,<br/>deployment, service"]
    apply --> setimg["kubectl set image<br/>this is what creates a revision"]
    setimg --> status{"kubectl rollout status --timeout=120s"}

    status -- ready --> ok([rolled out])
    status -- "stalled" --> kdecide{--auto-rollback?}
    kdecide -- yes --> undo["./encore.sh --k8s<br/>kubectl rollout undo"]
    kdecide -- no --> kmanual([print the options, exit 3])

    subgraph controller["what the cluster is doing meanwhile"]
        rs["new ReplicaSet scales up"] --> ready{"readinessProbe passes?"}
        ready -- yes --> ep["Pod joins the Service endpoints<br/>an old Pod may now be removed"]
        ready -- no --> hold["Pod stays out of rotation<br/>old Pods keep all the traffic"]
    end
```

`kubectl rollout undo` is literally an encore: it replays a revision the
cluster already has, rather than building anything new.

## Where the two modes differ, and why that is the point

| | Docker mode | Kubernetes mode |
|---|---|---|
| Wait for healthy | `curl -sf` retry loop in the script | `kubectl rollout status` |
| Health definition | external probe from the host | `readinessProbe` + `livenessProbe` |
| Keep the old version alive | candidate on a second port | `maxUnavailable: 0`, `maxSurge: 1` |
| Rollback source | image tags plus `deploy_history.log` | old ReplicaSets, `revisionHistoryLimit` |
| Rollback command | `./encore.sh 1.1.0` | `kubectl rollout undo` |
| Who reruns the health check | nobody, it runs once per deploy | the kubelet, forever |

Enhancements 1 to 7 exist to make that right-hand column legible. It is much
easier to trust `rollout status` after having written the loop it replaces.

## Observability data flow

Two independent lifecycles joined by one Docker network. The app is created
and destroyed by `showtime.sh`; the stack is created and destroyed by
`docker compose`. Neither can take the other down by accident.

```mermaid
flowchart LR
    subgraph net["docker network: soundcheck-net"]
        app["soundcheck-app<br/>created by showtime.sh"]
        prom[Prometheus]
        am[Alertmanager]
        loki[Loki]
        pt[Promtail]
        graf[Grafana]
    end

    hist[("deploy_history.log<br/>written by showtime + encore")]

    app -- "scrape /metrics/prometheus every 10s" --> prom
    prom -- "rules fire" --> am
    hist -- "tail, parse JSON, label" --> pt
    app -- "container stdout via the Docker API" --> pt
    pt --> loki
    prom --> graf
    loki --> graf
```

The `soundcheck-app` name is a network alias, not a hostname anyone
configured. Every deploy destroys the container behind it and the name keeps
resolving, which is service discovery in its simplest honest form.

### The two success-rate checks

Both exist on purpose and they are not equivalent.

| | `soundcheck.sh` | `alert_rules.yml` |
|---|---|---|
| Reads | `success_rate_percent`, a lifetime average | `rate(soundcheck_requests_total[5m])` |
| Reacts in | never, on a long-lived process | about five minutes |
| Needs | curl | a running Prometheus |
| Is | the torch in the drawer | the lighting rig |

After a week of uptime, ten minutes of total failure barely moves a lifetime
average, because the denominator is a week of successes. That is why the
Prometheus rule is the one that should page anyone, and why the shell check is
still worth keeping: it works when nothing else is running.

## Relationship to the other repos

- [`radio-kiosk`](https://github.com/iagorp6/radio-auto-pi) is broadcast: one
  device, kept on air by a watchdog. `station.conf` there and
  `config/retention.env` here are the same config-and-data instinct.
- **`soundcheck`** (this repo) is one service, deployed and watched by hand,
  then again by an orchestrator.
- [`ensemble`](https://github.com/iagorp6/ensemble) is the whole platform:
  Terraform, Ansible, K3s on a cloud VM, ArgoCD reconciling Git, and a
  `metronome` layer running this same Prometheus/Grafana/Loki/Alertmanager
  set at cluster scale.

The overlap with `metronome` is intentional and bounded. This repo runs that
stack small, self-contained, for one app, with the config written out by hand
so the mechanism is visible. `ensemble` runs it as Helm releases reconciled by
ArgoCD across a cluster. Same four components, deliberately different scale
and delivery method. Nothing here should grow into GitOps; that boundary is
what keeps the two repos from being the same project twice.
