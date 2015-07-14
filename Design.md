# Introduction #

This wiki page describes how PPSS is designed, how it works and which techniques are used.

**Please note that the design has changed with version 2.80 and differs from older versions.**

# Design #

There are two main ingredients that must be supplied to PPSS

  1. A list of items that must be processed:
    * either a text file containing one item per line. These items can represent whatever you want;
    * or a directory containing files that must be processed.
  1. A command that must be executed for each item.

For every item the specified command will be executed with the item supplied as an argument.

  * At any given moment there will be no more commands running in parallel other than specified by the command-line or based on the detected number of cpu cores.
  * Two parallel running processes should never interfere or collide with each other by processing the same item.
  * PPSS should not poll but wait for events to occur and 'do nothing' if there is nothing to do.  It must be event-driven.

## Communication between parent and child processes ##

One of the main difficulties for shell scripts is interprocess communication. There is no communication mechanism for child and parent processes to communicate with each other. A solution might be the use of signals with the 'trap' command to catch events, however tests have proven that this is not reliable. The trap mechanism that bash employs is inherently unreliable (by design). During the time period the trap command is processing a trap,  additional traps are ignored. Therefore, it is not possible to create a reliable mechanism using signals. There is actually a parallel processing shell script available on the web that is based on signals, and suffers exactly from this problem, which makes it unreliable.

However, repeated tests have determined that communication between processes using a FIFO named pipe is reliable and can be used for interprocess communication. PPSS uses a FIFO to allow a child process to communicate with the parent process.

Within PPSS, a child process only tells the master process one thing: 'I finished processing'. Either a new process is started processing the next item.

## Queue management ##

There is a single listener process that is just waiting for events to occur, by listening to a FIFO. The most important event is that a worker process should be started. This listener process will request a new item and will start a worker process to process this item.

Since the listener is the central process that requests items, no locking mechanism is required. Versions of PPSS before 2.80 had a cumbersome locking mechanism to prevent race conditions, however as of 2.80 this is no longer necessary.

Locking is only used to lock individual items. This allows multiple instances of PPSS to process the same local pool of items. For example, you started PPSS with two workers, but it seems that there is room for more workers. Just execute PPSS again with the same parameters and you will have two instances of PPSS processing the same bunch of items.

## Technical design ##

![http://home.quicknet.nl/mw/prive/nan1/got/ppss-schema.png](http://home.quicknet.nl/mw/prive/nan1/got/ppss-schema.png)

### Function: get\_all\_items ###

The first step of PPSS is to read all items that must be processed into a special text file. Items are read from this file using 'sed' and fed to the get\_item function.

### get\_item function ###

If called, an item will be read from the special input file and a global counter is increased, so the next time the function is executed, the next item on the list is returned. Sed is used to read a particular line number from the internal text file containing item names. The line number is based on a global counter that is increased each time an item is returned.

### Function: listen\_for\_job ###

The listen\_for\_job function is a process running in the background that listens on a FIFO special file (named pipe).

For every messages that is received, the listener will execute the 'get\_item' function to get an item. The commando function is then executed with this item as an argument. The commando function is run as a background process.

If the list of items has been processed, the get\_item function will return with a non-null return code, and the listen\_for\_job function will not start a new commando process. Thus over time, when commando jobs finish, all jobs die out. Once listen\_for\_job registers that all running jobs have died, it kills of PPSS itself.

The listen\_for\_job function keeps a counter for every worker thread that dies. Once this number hits the maximum number of parallel workers (like 4 if you have a quad-core CPU), it will terminate itself and eventually PPSS itself.

The whole listen\_for\_job function is executed as a background process. This function is the only permanent (while) loop running and is often blocked when no input is received, so it is doing nothing most of the time. This means that if PPSS has nothing to do, your system won't be wasting CPU cycles on some looping or polling.

### Function: start\_all\_workers ###

For every available cpu core, a thread will be started. If a user manually specifies a number of threads, that number will override the detected number of CPU cores.

So the start\_single\_worker function is called for each thread. This function just sends a message to the FIFO. There, it will be picked up by the listener process, which will request an item and execute the commando function to process the item.

### Command function ###

The command function performs the following tasks:

  * check if a supplied item has been processed already, if so, skip it. If a job log exists, the item is skipped.
  * execute the user-supplied command with the item as an argument
  * execute the 'start\_single\_worker' function to start a new job for a new item.

The third option is the most relevant. After the command finishes, it calls the start\_single\_worker function. The snake biting-its-own-tail mechanism. Essentially, a running thread keeps itself running by starting a new thread after it finishes, until there are no items to process.

### start\_new\_worker function ###

The start\_new\_worker function will send a message to the fifo to inform the listener process that a commando should be executed.