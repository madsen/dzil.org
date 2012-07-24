#!/usr/bin/env perl
# vim:ft=perl:
#---------------------------------------------------------------------
# Generate the plugin catalog from plugins-*.pod & tags.pod
# Christopher J. Madsen <perl@cjmweb.net>
#
# Usage: build-plugins.pl SRC_DIR DEST_DIR
#---------------------------------------------------------------------

use 5.010;
use strict;
use warnings;

use File::pushd qw(pushd);
use Path::Class qw(dir file);
use Pod::CYOA::XHTML ();
use Pod::PluginCatalog ();
use String::RewritePrefix 0.005
  rewrite => {
    -as => 'plugin_rewriter',
    prefixes => { ''  => 'Dist::Zilla::Plugin::',
                  '@' => 'Dist::Zilla::PluginBundle::' },
  };

#---------------------------------------------------------------------
sub pod_to_html
{
  my $parser = Pod::CYOA::XHTML->new;
  $parser->output_string(\my $html);
  $parser->html_h_level(3);
  $parser->html_header('');
  $parser->html_footer('');
  $parser->perldoc_url_prefix("https://metacpan.org/module/");
  $parser->parse_string_document( shift );

  $html;
} # end pod_to_html

#=====================================================================
my $src_dir  = dir( $ARGV[0] || die "$0 src dest" );
my $dest_dir = dir( $ARGV[1] || die "$0 src dest" );

$dest_dir->mkpath;

my $catalog = Pod::PluginCatalog->new(
  namespace_rewriter => \&plugin_rewriter,
  pod_formatter      => \&pod_to_html,
  perlio_layers      => ':encoding(cp1252)',
);

{
  my $cd = pushd($src_dir);

  for my $file ('tags.pod', glob("plugins-*.pod")) {
    say "reading $file...";
    $catalog->add_file($file);
  }
}

#---------------------------------------------------------------------
my $header = <<'END_HEADER';
<html>
<head>
  <title>Dist::Zilla - Plugins{{ $tag ? " - $tag" : '' }}</title>
  <link rel='stylesheet'  type='text/css' href='../style.css' />
  <link rel='stylesheet'  type='text/css' href='../catalog.css' />
  <link rel='stylesheet'  type='text/css' href='../ppi-html.css' />
  <link rel='stylesheet'  type='text/css' href='../vim-html.css' />
</head>

<body>
  <h1><a href='../index.html'>&gt; dzil</a></h1>
  <div id='content'>
    <h2><a href='index.html'>Plugin Catalog</a>{{ $tag ? " - $tag" : '' }}</h2>
{{ $tag_description // ($tag ? '' : <<'END');
<p>The plugins are categorized under the following tags.  A plugin may
appear under multiple tags.</p>
END
}}
    <div id='catalog'>
END_HEADER

my $footer = <<'END_FOOTER';
    </div>
    <div>
      You can fork and improve <a href='https://github.com/rjbs/dzil.org'>this
      documentation on GitHub</a>!
    </div>
  </div>
</body>
</html>
END_FOOTER

{
  my $cd = pushd($dest_dir);

  say "writing plugin catalog...";

  $catalog->generate_tag_pages($header, <<'END PLUGIN', $footer);
<h3><a href="https://metacpan.org/module/{{$module}}">{{$name}}</a>{{

  $OUT .= "<span class='author'>by <a href='https://metacpan.org/author/$author'>$author</a></span>"
    if $author;

  if (@other_tags) {
    $OUT .= "<span class='xrefs'>(also tagged: "
         . join(', ', map { "<a href='$_.html'>$_</a>" } @other_tags)
         . ")</span>\n";
  }
}}</h3>
{{$description}}
END PLUGIN

  $catalog->generate_index_page($header, <<'END INDEX', $footer);
<h4><a href="{{$tag}}.html">{{$tag}}</a></h4>
{{$description}}
END INDEX
}

# Local Variables:
# compile-command: "perl build-plugins.pl . ../../out/plugins"
# End:
