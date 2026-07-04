I am creating a neovim plugin in lua to do the following:

Create an AI agent plugin using the ACP protocol. That is more tightly integrated into the vim/neovim way of thinking, taking inspiration from plugins such as vim-fugitive.

There is a main screen where you can see all the sessions (similar to fugitives 'G' command), on that screen you can see if an agent is running. it should display which acp provider (i.e. the pi agent was used).

Pressing 'Enter' on the session, shows the entire history as a normal non-modifiable buffer. Currently i'm thinking the client (user) adds a prompt via the normal nvim cmd window. You should be able tto share context like files, and even the normal '<,'> when in visual mode to share code.

There could also be a more nicely formatted version which doesn't have the tool & reasoning but just the prompts & outputs.

Each message should show what model was used and what mode (this shouldn't use the acp modes but rather the session config options).

You should be able to view a nicely formatted plan buffer if the session includes a plan.

The session buffer and plan buffer should automatically update with the updates from the agent.

At the moment I'm thinking the buffer line shows the currently selected model, thinking/effort variant, percentage of context window used, what the agent is (which provider), and the price of the session.

All edits, writes are made as diffs. You can view these are side by side (similar to how fugitive handles conflicts/diffs where you can view them side-by-side, have a 3 way split) or you can view them inline. You cannot accept all edits and must review and accept edits one by one.

You should be able to see/navigate all the edits in the quickfix if desired.


Architecture wise:
- pure lua implementation?
