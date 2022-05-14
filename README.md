# dstr
Because cut is hard.

## Usage

```
dstr "[destructoring] output" executable?
```

### Destructoring
dstr splits its input from system in, and uses the destructoring expression to bind
each part of the split input to a symbol name.

`[a b]` &ensp; binds the first and second parts of the input to `a` and `b`.

Underscore `_` can be used to skip input.

`[_ b]` &ensp; binds only the second part of the input to `b`.


Inserting a ellipsis `...` into the expression will tell dstr to skip to the end of the input.

`[a ... z]` &ensp; binds the first and last parts of the input to `a` and `z`.

`[a ... y _]` &ensp; binds the first and the second last parts of the input to `a` and `y`.

### Output
The output consists of a list of symbols and strings.

`[a b] b a` &ensp; Outputs `b` then `a`

To output a string use single quotes `'`

`[a] 'Look: ' a` &ensp; Outputs the string `"Look:"` then `a`

dstr supports string interplation with `{symbol}`

`[a] 'Look: {a}'` will replace `{a}` with the value of the symbol `a`  


## Examples


Print the second last item
```
$echo AA BB CC DD | dstr "[... c _] c"
> CC
```

Use string interpolation to join inputs
```
$echo AA BB CC DD | dstr "[a ... d] '{a}_{d}'"
> AA_DD
```

Extract filename and size from ls
```
$ls -ld * | dstr "[_ _ _ _ si ... fi] fi 'size:' si"
> build.zig size: 481
> LICENSE size: 1073
> README.md size: 217
> src size: 4096
> zig-cache size: 4096
> zig-out size: 4096
```

Send output to another executable
```
$ cat test.sh 
> #!/bin/bash
> echo  "Invoked:" $0 $1

$ ls -ld * | dstr "[_ _ _ _ si ... fi] fi 'size:' si" ./test.sh
> Invoked: ./test.sh build.zig
> Invoked: ./test.sh LICENSE
> Invoked: ./test.sh README.md
> Invoked: ./test.sh src
> Invoked: ./test.sh test.sh
> Invoked: ./test.sh zig-cache
> Invoked: ./test.sh zig-out
```


## TODO
* csv parsing
* use files as input
* support more escape characters like \n and \t