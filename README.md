# Metaprogramming in Zig and parsing a bit of CSS

Minimal project to demonstrate metaprogramming in Zig to match parsed
key-value pairs to struct field members and later print out the struct
dynamically as well.

This was live-streamed on [my Twitch](https://twitch.tv/eatonphil).

Blog post to come shortly.

```console
$ zig build-exe main.zig
$ ./main tests/basic.css
selector: div
  background: white

```
