Legs parked here are NOT deployed (the ApplicationSets read `environments/*.yaml` only).
Bring one up for the multi-leg tests and park it again afterwards:

    scripts/leg.sh up leg2      # git mv + commit + push, then Secrets/Konnect for the leg
    scripts/leg.sh down leg2
