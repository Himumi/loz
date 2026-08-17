## Abstract Syntax Tree

- program    -> declaration* end_of_file ;

- declaration   -> class_declaration
                 | fun_declaration
                 | var_declaration
                 | statement ;
- var_declaration  -> "var" IDENTIFIER ( "=" expression )? ";" ;
- fun_declaration -> "fun" function ;
- class_declaration -> "class" IDENTIFIER ( "<" IDENTIFIER )?
                       "{" function* "}" ;

- function -> IDENTIFIER "(" parameters? ")" block_statement ;
- parameters -> IDENTIFIER ( "," IDENTIFIER )* ;

- statement    -> expression_statement
                | for_statement
                | if_statement
                | print_statement
                | return_statement
                | while_statement
                | block_statement ;
- expression_statement -> expression ";" ;
- print_statement  -> "print" expression ";" ;
- block_statement  -> "{" declaration* "}" ;
- if_statement   -> "if" "(" expression ")" statement
                  ( "else" statement )? ;
- while_statement  -> "while" "(" expression ")" statement ;
- for_statement   -> "for" "(" ( var_declaration | expression_statement | ";" )
                   expression? ";"
                   expression? ")" statement ;
- return_statement -> "return" expression? ";" ;

- expression   -> assignment ;
- assignment   -> ( call "." )? IDENTIFIER "=" assignment
                | logic_or ;

- logic_or    -> logic_and ( "or" logic_and)* ;
- logic_and    -> equality ( "and" equality)* ;

- equality    -> comparison ( ( "!=" | "==" ) comparison )* ;
- comparison   -> term ( ( ">" | ">=" | "<" | "<=" ) term )* ;
- term     -> factor ( ( "-" | "+" ) factor )* ;
- factor    -> unary ( ( "/" | "*" ) unary )* ;
- unary     -> ( "!" | "-" ) unary
             | call ;
- call     -> primary ( "(" arguments? ")" | "." IDENTIFIER )* ;
- arguments -> expression ( "," expression )* ;
- primary    -> "true" | "false" | "nil"
              | NUMBER | STRING
              | "(" expression ")" ;
              | IDENTIFIER ;
