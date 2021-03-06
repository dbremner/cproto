%{
/* $Id$
 *
 * Lexical analyzer for C function prototype generator
 *
 *	This is designed to parse lexically at the top level (e.g., of extern
 *	objects such as procedures).  The corresponding yacc-grammar expects
 *	that curly-braces (for function bodies) are recognized as a single
 *	token, BRACES.  Similarly, square-brackets and their contents are
 *	passed back as BRACKETS.
 *
 *	Assignments at the top level are data-initialization statements.
 *	These are returned as INITIALIZER.
 *
 *	The logic here recognizes tokens inside curly-braces, but does not
 *	pass them back to the grammar.
 *
 * Apollo extensions:
 *	"&" is ignored when creating lint-libraries, because we ignore
 *	expressions of all kinds.  Note that function-prototypes may use "&" to
 *	denote reference-parameters.  By ignoring that as well, we make the
 *	output compatible with lint (kludge).
 *
 *	Similarly, ignore "std_$call", since it is not compatible with lint.
 *
 *	CPP_INLINE handles a special case of the Apollo CC 6.7 compiler that
 *	uses inline attribute declarations, e.g.
 *
 *		int	foo #attribute[aligned(1)];
 *
 *	In CC 6.8 this behavior is hidden by a macro.
 *
 * VAX/VMS extensions:
 *	Treat the keywords 'globalref', etc., as 'extern'.
 *
 *	The keywords 'noshare' and 'readonly' are type-qualifiers.
 *
 * GCC extensions:
 *	The keywords '__attribute__', '__inline', '__inline__', '__signed',
 *	'__signed__'. and '__extension__'
 */

#define	result(nn)	count(); if (!brackets && unnested()) return(nn)

#define	is_IDENTIFIER	    save_text_offset();\
			    return type_of_name(yytext);

#if !OPT_LINTLIBRARY
#define gcc_attribute   absorb_special /* otherwise, we don't care */
#endif

#ifdef	apollo
#define	apollo_keyword
#define	apollo_special	absorb_special()
#else
#define	apollo_keyword	is_IDENTIFIER
#define	apollo_special	is_IDENTIFIER
#endif

#ifdef	vms
#define	vms_extern	save_text_offset(); return(T_EXTERN);
#define	vms_keyword	save_text_offset();
#else	/* unix */
#define	vms_extern	is_IDENTIFIER
#define	vms_keyword	is_IDENTIFIER
#endif	/* vms/unix */

char *	varargs_str;		/* save printflike/scanflike text */
int	varargs_num;		/* code to save "VARARGS" */
int	debug_trace;		/* true if we trace token-level stuff */
char	base_file[BUFSIZ];	/* top-level file name */

static int save_cpp;	/* true if cpp-text within curly braces */
static int in_cpp;	/* true while we are within cpp-text */
static int curly;	/* number of curly brace nesting levels */
static int ly_count;	/* number of occurances of %% */

#ifdef FLEX_SCANNER
/* flex scanner state */
static YY_BUFFER_STATE buffer_stack[MAX_INC_DEPTH];
#endif

static int inc_depth;				/* include nesting level */
static IncludeStack inc_stack[MAX_INC_DEPTH];	/* stack of included files */
static SymbolTable *included_files;		/* files already included */

static int  type_of_name      ARGS((char *name));
static void startCpp          ARGS((int level));
static void finishCpp         ARGS((void));
#if defined(apollo) || !OPT_LINTLIBRARY
static void absorb_special    ARGS((void));
#endif
#if OPT_LINTLIBRARY
static void gcc_attribute     ARGS((void));
#endif
static void update_line_num   ARGS((void));
static void save_text         ARGS((void));
static void save_text_offset  ARGS((void));
static void get_quoted        ARGS((void));
static void get_comment       ARGS((void));
static void get_cpp_directive ARGS((char *dest, unsigned n));
static void do_include        ARGS((char *f));
static void include_file      ARGS((char *name, int convert));
static void put_file          ARGS((FILE *outf));
static void put_quoted        ARGS((int c));

#if OPT_LINTLIBRARY
static int decipher_comment   ARGS((char *keyword, int len));
#endif

#ifdef yywrap
#undef yywrap
#endif
int yywrap ARGS((void));
%}

WS		[ \t]
LETTER		[A-Za-z$_]
DIGIT		[0-9]
ID		{LETTER}({LETTER}|{DIGIT})*
QUOTE		[\"\']

%s CPP1 INIT1 INIT2 CURLY LEXYACC ASM CPP_INLINE
%%

\n			{ save_text(); cur_file->line_num++;
			    cur_declarator = NULL; }

"/*"			{ save_text(); get_comment(); }
"//".*$ 		save_text();

<INITIAL>"&"		{ save_text(); return '&'; /* C++ ref-variable? */ }

<LEXYACC>^"%%"		{ save_text(); if (++ly_count >= 2) BEGIN INITIAL; }
<LEXYACC>^"%{"		{ save_text(); BEGIN INITIAL; }
<LEXYACC>{QUOTE}	get_quoted();
<LEXYACC>.		save_text();
<INITIAL>^"%}"		{ save_text(); BEGIN LEXYACC; }

<INITIAL>#{WS}* 	{ save_text(); startCpp(0); }
<INITIAL>"??="{WS}* 	{ save_text(); startCpp(0); }

<CPP1>attribute		{ BEGIN CPP_INLINE; /* apollo */}
<CPP1>options		{ BEGIN CPP_INLINE; /* apollo */}
<CPP_INLINE>[^;]*	finishCpp();

<CPP1>define{WS}+{ID}	{
			    char name[MAX_TEXT_SIZE], value[MAX_TEXT_SIZE];

			    save_text();
			    sscanf(yytext, "define %s", name);
			    get_cpp_directive(buf, sizeof(buf));
			    sscanf(buf, "%s", value);
			    new_symbol(define_names, name, value, DS_NONE);
			}

<CPP1>include{WS}*	{
			    save_text();
			    get_cpp_directive(buf, sizeof(buf));
			    if (buf[0] != '"' && buf[0] != '<') {
				Symbol *sym = find_symbol(define_names, buf);
				if (sym != NULL && sym->value != NULL) {
				    strcpy(buf, sym->value);
				} else {
				    buf[0] = '\0';
				}
			    }
			    if (buf[0] != '\0')
				do_include(buf);
			}

<CPP1>line{WS}+[0-9]+{WS}+\".*$  {
			    save_text();
			    sscanf(yytext, "line %d \"%[^\"]\"",
			     &cur_file->line_num, cur_file->file_name);
			    cur_file->line_num--;
			    track_in();
			    finishCpp();
			}
<CPP1>[0-9]+{WS}+\".*$  {
			    save_text();
			    sscanf(yytext, "%d \"%[^\"]\"", &cur_file->line_num,
			     cur_file->file_name);
			    cur_file->line_num--;
			    track_in();
			    finishCpp();
			}
<CPP1>[0-9]+.*$ 	{
			    save_text();
			    sscanf(yytext, "%d ", &cur_file->line_num);
			    cur_file->line_num--;
			    track_in();
			    finishCpp();
			}

<CPP1>. 		{ save_text(); get_cpp_directive(NULL, 0); }

<INITIAL>"("		{ save_text_offset(); return '('; }
<INITIAL>")"		{
			    save_text();
			    if (cur_file->convert)
				cur_file->begin_comment =
				 ftell(cur_file->tmp_file);
			    return ')';
			}
<INITIAL>"*"		{ save_text_offset(); return '*'; }
<INITIAL>[,;]		{
			    save_text();
			    if (cur_file->convert)
				cur_file->begin_comment =
				 ftell(cur_file->tmp_file);
			    return yytext[0];
			}
<INITIAL>"..."		{ save_text(); return T_ELLIPSIS; }
<INITIAL>\"		{
			    get_quoted();
			    return T_STRING_LITERAL;
			}

<INITIAL>asm		{ save_text(); BEGIN ASM; return T_ASM; }
<ASM>"("		save_text();
<ASM>")"		{ save_text(); BEGIN INITIAL; return T_ASMARG; }
<ASM>{QUOTE} 		get_quoted();
<ASM>. 			save_text();

<INITIAL>__?based[^(]*\([^)]*\)	{ save_text_offset(); return T_TYPE_QUALIFIER; }

<INITIAL>auto		{ save_text_offset(); return T_AUTO; }
<INITIAL>extern 	{ save_text_offset(); return T_EXTERN; }
<INITIAL>register	{ save_text_offset(); return T_REGISTER; }
<INITIAL>static 	{ save_text_offset(); return T_STATIC; }
<INITIAL>typedef	{ save_text_offset(); return T_TYPEDEF; }
<INITIAL>inline 	{ save_text_offset(); return T_INLINE; }

<INITIAL>_Bool		{ save_text_offset(); return T_Bool; }
<INITIAL>_Complex	{ save_text_offset(); return T_Complex; }
<INITIAL>_Imaginary	{ save_text_offset(); return T_Imaginary; }

<INITIAL>char		{ save_text_offset(); return T_CHAR; }
<INITIAL>double 	{ save_text_offset(); return T_DOUBLE; }
<INITIAL>float		{ save_text_offset(); return T_FLOAT; }
<INITIAL>int		{ save_text_offset(); return T_INT; }
<INITIAL>void		{ save_text_offset(); return T_VOID; }
<INITIAL>long		{ save_text_offset(); return T_LONG; }
<INITIAL>short		{ save_text_offset(); return T_SHORT; }
<INITIAL>signed 	{ save_text_offset(); return T_SIGNED; }
<INITIAL>unsigned	{ save_text_offset(); return T_UNSIGNED; }

<INITIAL>enum		{ save_text_offset(); return T_ENUM; }
<INITIAL>struct 	{ save_text_offset(); return T_STRUCT; }
<INITIAL>union		{ save_text_offset(); return T_UNION; }
<INITIAL>va_dcl		{ save_text_offset(); return T_VA_DCL; }

<INITIAL>__signed 	{ save_text_offset(); return T_SIGNED; }
<INITIAL>__signed__ 	{ save_text_offset(); return T_SIGNED; }
<INITIAL>__inline 	{ save_text_offset(); return T_INLINE; }
<INITIAL>__inline__ 	{ save_text_offset(); return T_INLINE; }
<INITIAL>__extension__ 	{ save_text_offset(); return T_EXTENSION; }
<INITIAL>__attribute__	{ gcc_attribute(); }

<INITIAL>globalvalue	{ vms_extern; }
<INITIAL>globalref	{ vms_extern; }
<INITIAL>globaldef	{ vms_extern; }

<INITIAL>"std_$call"	{ apollo_keyword; }
<INITIAL>"__attribute"	{ apollo_special; }

<INITIAL>{ID}		{ is_IDENTIFIER }

<INITIAL>\[[^\]]*\]	{
			    /* This can't handle the case where a comment
			     * containing a ] appears between the brackets.
			     */
			    save_text_offset();
			    update_line_num();
			    return T_BRACKETS;
			}
<INITIAL>"??("[^?]*"??)"	{
			    save_text_offset();
			    update_line_num();
			    return T_BRACKETS;
			}

<INITIAL>"="		{ save_text(); BEGIN INIT1; return '='; }
<INIT1>"{"		{ save_text(); curly = 1; BEGIN INIT2; }
<INIT1>[,;]		{
			    unput(yytext[yyleng-1]);
			    BEGIN INITIAL;
			    return T_INITIALIZER;
			}
<INIT1>{QUOTE}		get_quoted();
<INIT1>.		save_text();

<INIT2>"{"		{ save_text(); ++curly; }
<INIT2>"}"		{
			    save_text();
			    if (--curly == 0) {
				BEGIN INITIAL;
				return T_INITIALIZER;
			    }
			}
<INIT2>{QUOTE}		get_quoted();
<INIT2>.		save_text();

<INITIAL>"{"		{
			    save_text();
			    curly = 1;
			    return_val =
			    returned_at = FALSE;
			    BEGIN CURLY;
			    return T_LBRACE;
			}
<CURLY>"{"		{ save_text(); ++curly; }
<CURLY>"}"		{
			    save_text();
			    if (--curly == 0) {
				BEGIN INITIAL;
				return T_MATCHRBRACE;
			    }
			}
<CURLY>{QUOTE}		get_quoted();
<CURLY>"return"		{ save_text(); returned_at = TRUE; }
<CURLY>";"		{ save_text(); returned_at = FALSE; }
<CURLY>#{WS}* 		{ save_text(); startCpp(1); }
<CURLY>"??="{WS}* 	{ save_text(); startCpp(1); }
<CURLY>.		{ save_text(); return_val |= returned_at; }

[ \r\t\f]+		save_text();
.			{
			    save_text();
			    put_error();
			    fprintf(stderr, "bad character '%c'\n", yytext[0]);
			}
%%

static void
startCpp (level)
int level;
{
    save_cpp = level;
    in_cpp = TRUE;
    BEGIN CPP1;
}

static void
finishCpp()
{
    in_cpp = FALSE;
    if (save_cpp)
    	BEGIN CURLY;
    else
	BEGIN INITIAL;
}

/*
 * Skip over embedded __attribute/__attribute_ syntax.
 */
#if defined(apollo) || !OPT_LINTLIBRARY
static void
absorb_special ()
{
    int	c;
    int	nest	= 0;
    while ((c = input()) > 0) {
	if (c == '(')
	    nest++;
	else if (c == ')') {
	    if (--nest <= 0)
		break;
	}
    }
}
#endif

#if OPT_LINTLIBRARY
/*
 * This recognizes some of the special attribute macros defined by gcc:
 *	noreturn
 *	format(printf,n,m)
 *	format(scanf,n,m)
 * and uses that information to construct equivalent lint-library text.
 * (It's a distinct piece of code from the 'absorb_special()' function to
 * avoid spurious matches with non-gcc compilers).
 */
static void
gcc_attribute ()
{
    int	c, num1, num2;
    int	nest = 0;
    int	len = 0;
    char bfr[BUFSIZ];

    while ((c = input()) > 0) {
	if (len < sizeof(bfr)-1 && !isspace(c))
	    bfr[len++] = c;
	if (c == '(')
	    nest++;
	else if (c == ')') {
	    if (--nest <= 0)
		break;
	}
    }
    bfr[len] = '\0';
    if (!strcmp(bfr, "((noreturn))")) {
	exitlike_func = TRUE;
    } else if (sscanf(bfr, "((format(printf,%d,%d)))", &num1, &num2) == 2) {
	(void)sprintf(bfr, "PRINTFLIKE%d", varargs_num = num1);
	varargs_str = xstrdup(bfr);
    } else if (sscanf(bfr, "((format(scanf,%d,%d)))", &num1, &num2) == 2) {
	(void)sprintf(bfr, "SCANFLIKE%d", varargs_num = num1);
	varargs_str = xstrdup(bfr);
    }
}
#endif

/* Decode the current token according to the type-of-name
 */
static int
type_of_name (name)
char *name;
{
    if (find_symbol(type_qualifiers, name) != NULL)
	return T_TYPE_QUALIFIER;
    else if (find_symbol(typedef_names, name) != NULL)
	return T_TYPEDEF_NAME;
    else if (find_symbol(define_names, name) != NULL)
	return T_DEFINE_NAME;
    else
	return T_IDENTIFIER;
}

boolean
is_typedef_name (name)
char *name;
{
    return (find_symbol(typedef_names, name) != NULL);
}

/* If the matched text contains any new line characters, then update the
 * current line number.
 */
static void
update_line_num ()
{
    char *p = yytext;
    while (*p != '\0') {
	if (*p++ == '\n')
	    cur_file->line_num++;
    }
}

/* Save the matched text in the temporary file.
 */
static void
save_text ()
{
#if OPT_LINTLIBRARY
    if (!in_cpp)
    	copy_typedef(yytext);
#endif
    if (cur_file->convert) {
	fputs(yytext, cur_file->tmp_file);
    }
}

/* Record the current position in the temporary file and write the matched text
 * to the file.
 */
static void
save_text_offset ()
{
    (void)strcpy(yylval.text.text, yytext);
#if OPT_LINTLIBRARY
    copy_typedef(yytext);
#endif
    if (cur_file->convert) {
	yylval.text.begin = ftell(cur_file->tmp_file);
	fputs(yytext, cur_file->tmp_file);
    } else
    	yylval.text.begin = 0;
}

#if OPT_LINTLIBRARY
/* Decipher comments that are useful for lint (and making lint-libraries)
 */
static struct {
    int	varText;
    int	varargs;
    int	externs;
    int	preproz;
} cmtVal;

static int
decipher_comment (keyword, len)
char *keyword;
int len;
{
    if (len != 0) {
	int value;
	keyword[len] = '\0';

	/* these are recognized by some lint-programs */
	if (!strcmp(keyword, "VARARGS")) {
	    cmtVal.varargs = -1;
	} else if (sscanf(keyword, "VARARGS%d", &value) == 1) {
	    cmtVal.varargs = value;
	} else if (!strcmp(keyword, "PRINTFLIKE")) {
	    cmtVal.varargs = 1;
	    cmtVal.varText = TRUE;
	} else if (sscanf(keyword, "PRINTFLIKE%d", &value) == 1) {
	    cmtVal.varargs = value;
	    cmtVal.varText = TRUE;
	} else if (!strcmp(keyword, "SCANFLIKE")) {
	    cmtVal.varargs = 2;
	    cmtVal.varText = TRUE;
	} else if (sscanf(keyword, "SCANFLIKE%d", &value) == 1) {
	    cmtVal.varargs = value;
	    cmtVal.varText = TRUE;
	/* these are extensions added to simplify library-generation */
	} else if (!strcmp(keyword, "LINT_EXTERN")) {
	    cmtVal.externs = MAX_INC_DEPTH;
	} else if (sscanf(keyword, "LINT_EXTERN%d", &value) == 1) {
	    cmtVal.externs = value;
	} else if (!strcmp(keyword, "LINT_PREPRO")) {
	    cmtVal.preproz = -1;	/* the whole comment */
	} else if (sscanf(keyword, "LINT_PREPRO%d", &value) == 1) {
	    cmtVal.preproz = value;
	} else if (!strcmp(keyword, "LINT_SHADOWED")) {
	    lint_shadowed = TRUE;
	}
    }
    return 0;
}
#endif

static void
put_quoted (c)
int c;
{
    /* Modifying 'yytext[]' doesn't work well with FLEX, which simply
     * maintains 'yytext' as a pointer into its input buffer.  LEX copies
     * characters into the 'yytext[]' array.
     */
#if defined(FLEX_SCANNER) || !defined(YYLMAX)
    if (c != 0) {
	static char	temp[2];
	temp[0] = c;
	/* save_text */
# if OPT_LINTLIBRARY
	if (!in_cpp)
	    copy_typedef(temp);
# endif
	if (cur_file->convert) {
	    fputs(temp, cur_file->tmp_file);
	}
	/* update_line_num */
	if (c == '\n')
	    cur_file->line_num++;
    }

#else	/* this works fine on LEX (e.g., on SunOS 4.x) */

    if ((c == 0) || (yyleng+1 >= YYLMAX)) {
	save_text();
	update_line_num();
	yyleng = 0;
    }
    if (c != 0) {
	yytext[yyleng++] = c;
	yytext[yyleng] = 0;
    }
#endif	/* LEX/FLEX */
}

/*
 * Scan past the characters in a backslash sequence
 */
/* Scan past quoted string.  Note that some strings may overflow 'yytext[]', so
 * we don't try to eat them in the lexical rules.
 */
static void
get_quoted ()
{
    int	delim = *yytext;
    int	c;

#if defined(FLEX_SCANNER) || !defined(YYLMAX)
    put_quoted(delim);
#endif
    while ((c = input()) != 0) {
	if (c == '\\') {
	    put_quoted(c);
	    if ((c = input()) == 0)
		break;
	    put_quoted(c);
	} else {
	    put_quoted(c);
	    if (c == delim)
		break;
	    if (c == '\n') {	/* recover from unbalanced */
		put_error();
		fprintf(stderr, "unbalanced quote character '%c'\n", delim);
		break;
	    }
	}
    }
    put_quoted(0);
}

/* Scan to end of comment.
 */
static void
get_comment ()
{
    int c, lastc = '\0';

#if OPT_LINTLIBRARY
    int len = 0;
    char keyword[BUFSIZ];

    keyword[len] = '\0';
    cmtVal.varText = 0;
    cmtVal.varargs = 0;
    cmtVal.externs = -1;
    cmtVal.preproz = 0;
#endif

    while ((c = input()) != 0) {
	if (cur_file->convert)
	    fputc(c, cur_file->tmp_file);

#if OPT_LINTLIBRARY
	if (!(isalnum(c) || c == '_' || c == '$')) {
	    int flag = cmtVal.preproz;
	    len = decipher_comment(keyword, len);
	    if (flag != cmtVal.preproz)
	    	lastc = '\0';
	} else if (len+1 < sizeof(keyword)) {
	    keyword[len++] = c;
	}
#endif

	switch (c) {
	case '\n':
	    cur_file->line_num++;
#if OPT_LINTLIBRARY
	    if (cmtVal.preproz != 0 && lastc != '\0')
		fputc(lastc, stdout);
	    if (cmtVal.preproz > 0)	/* if negative, we pass everything */
		cmtVal.preproz -= 1;
#endif
	    break;
	case '/':
	    if (lastc == '*') {
		if (cur_file->convert) {
		    if (func_params && cur_declarator) {
			cur_declarator->begin_comment = cur_file->begin_comment;
			cur_file->begin_comment = ftell(cur_file->tmp_file);
			cur_declarator->end_comment = cur_file->begin_comment;
			cur_declarator = NULL;
		    } else {
			cur_file->end_comment = ftell(cur_file->tmp_file);
		    }
		}
#if OPT_LINTLIBRARY
		(void)decipher_comment(keyword, len);
		if (cmtVal.varargs != 0) {
		    if ((varargs_num = cmtVal.varargs) != 0
		     && cmtVal.varText != 0) {
			if (varargs_str != 0)
			    free(varargs_str);
			varargs_str = xstrdup(keyword);
		    }
		}
		if (cmtVal.externs != -1)
		    extern_in = cmtVal.externs;
		if (cmtVal.preproz != 0)
		    fputc('\n', stdout);
#endif
		return;
	    }
	    /* FALLTHRU */
	default:
#if OPT_LINTLIBRARY
	    if (cmtVal.preproz != 0 && lastc != '\0')
		fputc(lastc, stdout);
#endif
	    break;
	}
	lastc = c;
    }
}

/* Scan rest of preprocessor directive.  If <dest> is not NULL, then store
 * the text in the buffer pointed to by <dest> having size <n>.
 */
static void
get_cpp_directive (dest, n)
char *dest;		/* buffer to store directive text */
unsigned n;		/* size of buffer to store directive text */
{
    char c, lastc[4];

    lastc[0] = lastc[1] = lastc[2] = lastc[3] = '\0';
    if (dest != NULL)
	*dest = '\0';

    while ((c = input()) != 0) {
	if (cur_file->convert)
	    fputc(c, cur_file->tmp_file);

	switch (c) {
	case '\n':
	    cur_file->line_num++;
	    if (lastc[2] != '\\' && strcmp(lastc, "?\?/") != 0) {
		finishCpp();
		return;
	    }
	    break;
	case '*':
	    if (lastc[2] == '/')
		get_comment();
	    break;
	}
	lastc[0] = lastc[1];
	lastc[1] = lastc[2];
	lastc[2] = c;

	if (dest != NULL && n > 1) {
	    *dest++ = c;
	    *dest = '\0';
	    --n;
	}
    }
}

/* Return a pointer to the current file name.
 */
char *
cur_file_name ()
{
    return cur_file->file_name;
}

/* Return the current line number.
 */
unsigned
cur_line_num ()
{
    return cur_file->line_num;
}

/* Return the current temporary output file.
 */
FILE *
cur_tmp_file ()
{
    return cur_file->tmp_file;
}

/* Set the modify flag for the current file.
 */
void
cur_file_changed ()
{
    cur_file->changed = TRUE;
}

/* Return the temporary file offset of beginning of the current comment.
 */
long
cur_begin_comment ()
{
    return cur_file->begin_comment;
}

/* Return the text of the current lexical token.
 */
char *
cur_text ()
{
    return yytext;
}

#if !HAVE_TMPFILE
/*
 * tmpfile() - return a FILE* for a temporary file that will be
 * removed automatically when the program exits.
 *
 * Not all systems have the ANSI tmpfile() function yet...
 *
 * DaviD W. Sanderson (dws@cs.wisc.edu)
 */
FILE *
tmpfile ()
{
    char name[MAX_TEXT_SIZE];
    char *tmpdir;
    FILE *f;

    if ((tmpdir = getenv("TMPDIR")) == (char *)0)
    {
	tmpdir = "/tmp";
    }
    sprintf(name, "%s/TfXXXXXX", tmpdir);
    mktemp(name);

    if ((f = fopen(name, "w+")) == (FILE *)0)
    {
	return (FILE *)0;
    }

    if (unlink(name) == -1)
    {
	fclose(f);
	return (FILE *)0;
    }

    return f;
}
#endif /* !HAVE_TMPFILE */

/* Push a file onto the include stack.	The stream yyin must already
 * point to the file.
 */
static void
include_file (name, convert)
char *name;		/* file name */
int convert;		/* if TRUE, convert function definitions */
{
    ++inc_depth;
    cur_file = inc_stack + inc_depth;
    cur_file->file = yyin;
    cur_file->base_name = xstrdup(name);
    cur_file->file_name = strcpy(xmalloc(MAX_TEXT_SIZE), name);
    cur_file->line_num = 1;
    cur_file->convert = convert;
    cur_file->changed = FALSE;

#ifdef FLEX_SCANNER
    buffer_stack[inc_depth] = yy_create_buffer(yyin, YY_BUF_SIZE);
    yy_switch_to_buffer(buffer_stack[inc_depth]);
#endif

    if (convert) {
	cur_file->begin_comment = cur_file->end_comment = 0;
	cur_file->tmp_file = tmpfile();
	if (cur_file->tmp_file == NULL) {
	    fprintf(stderr, "%s: cannot create temporary file\n", progname);
	    cur_file->convert = FALSE;
	}
    }
}

#define BLOCK_SIZE 2048

/* Copy converted C source from the temporary file to the output stream.
 */
static void
put_file (outf)
FILE *outf;
{
    char block[BLOCK_SIZE];
    long filesize;
    unsigned nread, count;

    filesize = ftell(cur_file->tmp_file);
    fseek(cur_file->tmp_file, 0L, 0);
    while (filesize > 0) {
	count = (filesize < BLOCK_SIZE) ? (unsigned)filesize : BLOCK_SIZE;
	nread = fread(block, sizeof(char), count, cur_file->tmp_file);
	if (nread == 0)
	    break;
	fwrite(block, sizeof(char), nread, outf);
	filesize -= nread;
    }
}

/* Remove the top of the include stack.
 */
void
pop_file (closed)
int closed;
{
    FILE *outf;

    if (!closed && (yyin != stdin))
	fclose(yyin);

    if (cur_file->convert) {
	if (yyin == stdin) {
	    put_file(stdout);
	} else if (cur_file->changed) {
	    if ((outf = fopen(cur_file->base_name, "w")) != NULL) {
		put_file(outf);
		fclose(outf);
	    } else {
		fprintf(stderr, "%s: cannot create file %s\n", progname,
		 cur_file->base_name);
	    }
	}

	fclose(cur_file->tmp_file);
    }
    free(cur_file->base_name);
    free(cur_file->file_name);

#ifdef FLEX_SCANNER
    yy_delete_buffer(YY_CURRENT_BUFFER);
#endif

    if (--inc_depth >= 0) {
	cur_file = inc_stack + inc_depth;
	yyin = cur_file->file;

#ifdef FLEX_SCANNER
	yy_switch_to_buffer(buffer_stack[inc_depth]);
#endif
    }
}

/* Process include directive.
 */
static void
do_include (file_spec)
char *file_spec; 	/* path surrounded by "" or <> */
{
    int stdinc; 	/* 1 = path surrounded by <> */
    char file[MAX_TEXT_SIZE], path[MAX_TEXT_SIZE];
    char match, *s;
    int i;
    unsigned n;
    FILE *fp;

    if (inc_depth >= MAX_INC_DEPTH-1) {
	put_error();
	fprintf(stderr, "includes too deeply nested\n");
	return;
    }

    if (file_spec[0] == '"') {
	match = '"';
	stdinc = 0;
    } else if (file_spec[0] == '<') {
	match = '>';
	stdinc = 1;
    } else {
	return;
    }
    s = strchr(file_spec+1, match);
    n = (s != NULL) ? (unsigned)(s - file_spec - 1) : 0;
    strncpy(file, file_spec+1, (size_t)n);
    file[n] = '\0';

    /* Do nothing if the file was already included. */
    sprintf(path, stdinc ? "<%s>" : "\"%s\"", file);
    if (find_symbol(included_files, path) != NULL)
	return;
    new_symbol(included_files, path, NULL, DS_NONE);

    for (i = stdinc != 0; i < num_inc_dir; ++i) {
	if (strlen(inc_dir[i]) == 0) {
	    strcpy(path, file);
	} else {
	    sprintf(path, "%s/%s", inc_dir[i], file);
	}
	if ((fp = fopen(path, "r")) != NULL) {
	    yyin = fp;
	    include_file(path, func_style != FUNC_NONE && !stdinc);
	    return;
	}
    }

    if (!quiet) {
	put_error();
	fprintf(stderr, "cannot read file %s\n", file_spec);
    }
}

/* When the end of the current input file is reached, pop a
 * nested include file.
 */
int
yywrap ()
{
    if (inc_depth > 0) {
	pop_file(FALSE);
	return 0;
    } else {
	return 1;
    }
}
