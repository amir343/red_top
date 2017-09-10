# README

`red_top` is an Erlang performance related tool for giving you a sense
of CPU utilisation per Erlang application in your system. It is
similar to Unix top but instead for Erlang processes and applications

## Minimum Requirements

- Erlang/OTP 17.0

## How to run

Check out this repository and compile it like this:

    # make all

Make sure that you include the beam files in your path the BEAM
process is looking for and then you can start `red_top` like this:

    application:start(red_top).

## Contributors

A big thanks to Kred core team at Klarna for their precious and
thoughtful contributions/feedbacks.
