# dstr
Because cut is hard.

## Download

[Releases](https://github.com/hjalmare/dstr/releases)

## Usage
dstr reads lines of input from system in, splits it and then binds it onto symbols that can be printed or sent to another executable. 
Similar to cut and awk.

```
dstr "destructoring output" executable?
```

### Destructoring
dstr splits input from system in, and uses a destructoring expression to bind
parts of the split input to a symbol name. 

There are two kinds of destructoring in dstr, _template destructoring_ which can be used on most text 
and _positional destructoring_ which can be used on space separated columns (and other csv formats in the future).

#### Template destructoring
Lets say you have a bunch of access logs that look like the following 

```
2022-05-04T11:13:39.686Z info: Received a GET request for /mypage
2022-05-04T11:13:40.286Z warn: Received a POST request for /mypage
``` 

and you want to rewrite it to another format. To do that you need to extract the different parts 
and then put them back in a different order.
Using template destructuring (written inside single quotes `' '`) you can replace the parts you want to extract
with `{symbol}` and the varying parts you do not care about with `{_}`.


```
$ cat log.log | dstr "'{ts} {_}: Received a {m} request for {url}' '{m} request for {url} at {ts}'"  
> GET request for /mypage at 2022-05-04T11:13:39.686Z
> POST request for /mypage at 2022-05-04T11:13:40.286Z
```

#### Positional destructoring
You have been given a db dump of a users table with the folowing space separated columns: 
id, email, age, pokemons, contact. 
And you need to extract the email and contact fields to feed into some other script. 
Positional destructoring is intended for this usecase and are written inside square brackets `[ ]`. 

```
$ cat dump.csv
> 543345 asdf@asdf.com 43 2 true
> 543346 qwerty@asdf.com 1 1 false
> 543347 foo@bar.com 38 19 true

$cat dump.csv | dstr "[_ em ... c] em c"
> asdf@asdf.com true
> qwerty@asdf.com false
> foo@bar.com true
```


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
| `endsWith(val1 val2)`   | `val1.endsWith(val2)`   | Returns true if `val1` ends with the value of  `val2`                              |
| `contains(val1 val2)`   | `val1.contains(val2)`   | Returns true if `val1` contains the value of  `val2`                               |
| `gt(val1 val2)`         | `val1.gt(val2)`         | Returns true if `val1` is greater than `val2`                                      |
| `lt(val1 val2)`         | `val1.lt(val2)`         | Returns true if `val1` is less than `val2`                                         |
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
$ echo AA BB CC DD | dstr "[... c _] c"
> CC
```

Use string interpolation to join inputs
```
$ echo AA BB CC DD | dstr "[a ... d] '{a}_{d}'"
> AA_DD
```

Extract filename and size from ls
```
$ ls -ld * | dstr "[_ _ _ _ si ... fi] fi 'size:' si"
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
* Nice errors and error checking
* csv parsing
* use files as input
* support more escape characters like \n and \t
* compiletime typecheck
* faster stdio
* escapes in template destructoring
* toggleable strict mode
* arg checks on all builtins
* Jit
* Regex support
* More builtins like trimming
