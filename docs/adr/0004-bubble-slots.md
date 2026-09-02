# Bubble-native features keep a pre-created slot under ~/.bubble

Record, settings, mounts, and persona each have a slot file so a new Mac has something to open. Secrets stay empty. Bootstrap creates a missing slot and never overwrites one that already exists, so a filled API key is not clobbered. We rejected shipping slots in git and rejected lazy-create-on-first-use: the agent and the user need a stable path before the feature is configured.
