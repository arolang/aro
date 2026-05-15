# Build an event-driven directory replicator with repository observers

Create an ARO application that replicates directory structure using repository observers instead of for-each loops.

The application needs two files:

- `main.aro` -- The `Application-Start` feature set. List all entries recursively from a template directory. Filter to get only directories using `Filter the <directories: List> from the <all-entries> where <isDirectory> is true`. Log the count. Store the entire filtered list into `<directory-repository>` -- the runtime automatically emits an observer event for each item.

- `observers.aro` -- Two repository observer feature sets (business activity: `directory-repository Observer`):
  - `Process Directory Entry` -- Extract the entry from `<event: newValue>`, extract the full path, split to remove the template prefix, extract the relative path, and create the directory with `Make the <dir> to the <path: relpath>`. Log each created directory.
  - `Audit Directory Changes` -- Extract changeType and repositoryName from the event, log an audit message.
