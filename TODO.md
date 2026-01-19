# TODO:
- [ ] Make sure agentic mode respects the mode that is selected on the prompt 
    - Meaning that the mode should always be set by the one in the prompt, since build is the default mode (the user need to actually write #plan on every request) this means that the user can write #plan message and then the next prompt in build mode so no input needed and the opencode still thinks he is in plan mode
- [ ] Questions like permissions to read files and run commands should have an input for the user
- [ ] Questions with predefined responses by the model should also be prompt by user input
- [ ] Closing nvim and calling :OCStop should actually kill every opencode serve that was launched
- [ ] Make sure that the number of ports that can be used for opencode serve actually is something that makes sense
- [ ] Add config input for custom ports to be used in the opencode serve
