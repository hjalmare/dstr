# dstr
Because cut is hard.

## Download

[Releases](https://github.com/hjalmare/dstr/releases)

## Usage
dstr reads input from system in, splits it and then binds it onto symbols that can be printed or sent to another executable. 
Similar to cut and awk.

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

dstr supports string interpolation with `{symbol}`

`[a] 'Look: {a}'` &ensp; will replace `{a}` with the value of the symbol `a`  


### Built in functions
Functions can either be invoked using c-like syntax where arguments are separated by a space `first(val 3)`.
Or dot syntax can be used like this: `val.first(3)` here val is inserted as the first argument to `first`.

There is currently a small selection of functions implemented.

| Function                | Dot syntax              | Description                                                                        |
|-------------------------|-------------------------|------------------------------------------------------------------------------------|
| `first(val num)`        | `val.first(num)`        | Takes the first `num` characters from `val`                                        |
| `rpad(val num)`         | `val.rpad(num)`         | Pads the right side of `val` with spaces so that it is `num` characters long       |
| `rpad(val num ptrn)`    | `val.rpad(num ptrn)`    | Pads the right side of `val` with `ptrn` so that it is `num` characters long       |
| `upper(val)`            | `val.upper()`           | Return the uppercaser version of `val`                                             |
| `eq(val1 val2)`         | `val1.eq(val2)`         | Returns true if `val1 = val2`                                                      |
| `startsWith(val1 val2)` | `val1.startsWith(val2)` | Returns true if `val1` starts with the value of `val2`                             |
| `endsWith(val1 val2)`   | `val1.endsWith(val2)`   | Returns true if  `val1`  ends with the value of  `val2`                            |
| `if(pred tr fa)`        | `pred.if(tr fa)`        | If `pred` is true returns `tr` else `fa`  Example: `if(a.eq(b) 'same' 'not same')` |

## Examples


A little bit of everything
```
$ ls -ld * | dstr "[... f] if(f.endsWith('.sh') 'Shell: {f}' 'File: {f}').upper()"
> SHELL: BUILD_PAK.SH
> FILE: BUILD.ZIG
> FILE: LICENSE
> FILE: README.MD
> SHELL: REL_TAG.SH
> FILE: SRC
> FILE: ZIG-CACHE
> FILE: ZIG-OUT
```

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
> echo  "Invoked:" $1 $2

$ ls -ld * | dstr "[_ _ _ _ si ... fi] fi 'size: {si}'" ./test.sh
> Invoked: build.zig size: 481
> Invoked: LICENSE size: 1073
> Invoked: README.md size: 1918
> Invoked: src size: 4096
> Invoked: test.sh size: 37
> Invoked: zig-cache size: 4096
> Invoked: zig-out size: 4096
```


## TODO
* Template based input parsing `'info: {msg} responseTime:{resptime}'`
* Nice errors and error checking
* Faster ref resolution
* csv parsing
* use files as input
* support more escape characters like \n and \t
* compiletime typecheck
* faster stdio