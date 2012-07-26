#!perl

use sanity;  ### LAZY: Will probably change to use strict/warnings later...

use List::AllUtils qw(min uniq firstidx);

use Pod::Elemental;
use Pod::Elemental::Transformer::Pod5;
use Text::Wrap;
use Pod::Strip;

use POSIX;
use Path::Class;
use File::Spec;
use File::Slurp;

use MetaCPAN::API;
use HTTP::Tiny::Mech;
use WWW::Mechanize::Cached::GZip;
use CHI;

use String::RewritePrefix 0.005
   rewrite => {
      -as => 'plugin_class',
      prefixes => {
         ''  => 'Dist::Zilla::Plugin::',
         '@' => 'Dist::Zilla::PluginBundle::',
         '>' => 'Dist::Zilla::App::Command::',
         '=' => ''
      },
   },
   rewrite => {
      -as => 'plugin_name',
      prefixes => {
         'Dist::Zilla::Plugin::'       => '' ,
         'Dist::Zilla::PluginBundle::' => '@',
         'Dist::Zilla::App::Command::' => '>',
         ''                            => '=',
      },
   }
;

#############################################################################

### LE BLACKLISTS! ###

# All of these support anything that works with $_ ~~ ARRAY 

# (ideally, things should die here first...)
my @BLACKLIST_DISTRO = (
   # IMPORTANT
   qr/-Author-/,
   qr/^Dist-Zilla-PluginBundle-[A-Z]+$/,
   qr/^Dist-Zilla-BeLike-/,
   qr/^Task-/,
   
   # More author modules
   qr/^Dist-Zilla-PluginBundle-LEONT-/,
   qr/^Dist-Zilla-PluginBundle-Bio[Pp]erl$/,
   'Dist-Zilla-Plugins-CJM',
   'Dist-Zilla-PluginBundle-Apocalyptic',
   'Dist-Zilla-Plugin-ApocalypseTests',
   'Dist-Zilla-PluginBundle-Rakudo',
   
   # CPAN Testers sez = EPIC FAIL
   'Dist-Zilla-Plugin-JSAN',
   'Dist-Zilla-Plugin-Web',
);

my @BLACKLIST_PLUGIN = (
   # IMPORTANT
   qr/^\=/,
   qr/^\>\w+::/,
   
   # Stubs for Foo::* plugins
   qw(
      GitHub
      GitFlow
      Git
      Subversion
      SVK
      Mercurial
      Run
   ),
);

my @BLACKLIST_CLASS = (
   # IMPORTANT
   qr/::Author::/,
   qr/^Dist::Zilla::PluginBundle::[A-Z]+$/,
);

#############################################################################
# Some other globals

my $root_dir = Path::Class::dir( File::Spec->curdir() )->parent->parent->subdir('tmp', '.webcache');

my (@EXISTING, @NEW, %PODS);
my $MCPAN = MetaCPAN::API->new(
   ua => HTTP::Tiny::Mech->new(
      mechua => _mcpan_set_agent_str(
         WWW::Mechanize::Cached::GZip->new(
            cache => CHI->new(
               namespace  => 'MetaCPAN',
               driver     => 'File',
               expires_in => '1d',
               root_dir   => $root_dir->stringify,
               
               # https://rt.cpan.org/Ticket/Display.html?id=78590
               on_set_error   => 'die',
               max_key_length => min( POSIX::PATH_MAX - length( $root_dir->subdir('MetaCPAN', 0, 0)->absolute->stringify ) - 4 - 8, 248),
            )
         )
      )
   )
);

my %ROLE2TAG = ( qw(
   AfterRelease       after-release
   BeforeRelease      before-release
   FileFinder         file-finder
   FileGatherer       file-gatherer
   FileMunger         file-munger
   FilePruner         file-pruner
   Git::Repo          git
   Git::Repo::More    git
   Git::LocalRepository git
   BuildRunner        install
   InstallTool        install
   MetaProvider       metadata
   MintingProfile     minting
   MintingProfile::ShareDir minting
   PrereqSource       prereqs
   Releaser           releaser
   ExecFiles          scripts
   TextTemplate       template
   Subversion         version-control
   VersionProvider    version-provider
) );

my $POD5 = 'Pod::Elemental::Element::Pod5';  # shorthand

#############################################################################

die "A 'new' directory already exists!  Clean it up, delete it, and then re-run!" if (-d 'new');

&populate_existing;
&find_moar_modules;
&create_new_pods;

#############################################################################

sub populate_existing {
   opendir( my $dh, File::Spec->curdir() );
   while (my $file = readdir $dh) {
      next unless (-f $file);
      next unless ($file =~ /\.pod$/);
      next if ($file eq 'tags.pod');

      printf 'Reading POD %-30s...', $file;
      my $doc = $PODS{$file} = Pod::Elemental->read_file($file);
      Pod::Elemental::Transformer::Pod5->new->transform_node($doc);
      foreach my $el (@{ $doc->children }) {
         if ($el->isa($POD5.'::Command') && $el->command eq 'plugin') {
            $el->content =~ /^(\S+)/;
            push @EXISTING, $1;
         }
         elsif (
            $el->isa($POD5.'::Region') && $el->format_name &&
            $el->children->[0] && $el->children->[0]->isa($POD5.'::Data')
         ) {
            $el->children->[0]->content =~ /^=plugin (\S+)/;
            push @EXISTING, $1;
         }
      }
      print "done\n";
   }
   closedir $dh;

   print "\nFound ".@EXISTING." documented plugins!\n\n";
}

sub create_new_pods {
   my $dir = Path::Class::dir( File::Spec->curdir() )->subdir('new');
   $dir->mkpath();

   foreach my $new (@NEW) {
      my ($plugin, $author, $description, $tags) = @$new;
      my $file = 'plugins-'.lc($author).'.pod';

      unless ($PODS{$file}) {
         $PODS{$file} = Pod::Elemental::Document->new();
         push @{ $PODS{$file}->children }, Pod::Elemental::Element::Pod5::Command->new(
            command => 'author',
            content => uc $author,
         );
      }

      my $children = $PODS{$file}->children;
      
      if ($description =~ /deprecated/i) {
         push @$children, Pod::Elemental::Element::Pod5::Region->new(
            children    => [ Pod::Elemental::Element::Pod5::Data->new( content => "=plugin $plugin\n$tags\n" ) ],
            format_name => 'deprecated',
            content     => '',
            is_pod      => 0,
         );
         next;
      }
      
      push @$children,
         Pod::Elemental::Element::Pod5::Command->new(
            command => 'plugin',
            content => "$plugin\n$tags",
         ),
         map { Pod::Elemental::Element::Pod5::Ordinary->new(
            content => wrap('','',$_),
         ) } (split /\n\n/, $description)
      ;
   }

   foreach my $file (sort keys %PODS) {
      my $filepath = $dir->file($file)->stringify;
      printf 'Writing POD %-30s...', $filepath;
      my $pod = $PODS{$file};
      my $content = $pod->as_pod_string;
      $content =~ s/^=pod\s*|\s*=cut\s*$//g;
      $content =~ s/^=plugin/\n=plugin/gm;  # P:E:D tends to remove multiple blank lines

      File::Slurp::write_file($filepath, $content."\n");
      print "done\n";
   }
}

sub find_moar_modules {
   my @EXISTING_CLASS = map { plugin_class($_) } @EXISTING;
   my %search_params;

   # First, get a list of distros, using various techniques
   my (@distros, %distro_author);
   foreach my $prefix ('', '@', '>') {
      my $ns = plugin_class($prefix.'*');  # Dist::Zilla::Plugin::*, etc.
      %search_params = (
         q      => join(' AND ', '"'.$ns.'"', 'status:latest', 'module.authorized:true'),
         fields => 'distribution,author',
         size   => 5000,
      );

      printf 'Searching MetaCPAN for distributions via "%-28s"...', $ns;
      my $details = $MCPAN->fetch( "file/_search", %search_params );
      @distros = uniq( @distros, map { $_->{fields}{distribution} } @{ $details->{hits}{hits} } );
      map { $distro_author{ $_->{fields}{distribution} } = $_->{fields}{author} } @{ $details->{hits}{hits} };
      printf 'found %3u hits (up to %3u distros total)'."\n", $details->{hits}{total}, scalar @distros;
   }

   # (another pass with releases of 'Dist-Zilla-*')
   %search_params = (
      q      => join(' AND ', '"Dist-Zilla-*"', 'status:latest'),
      fields => 'distribution,author',
      size   => 5000,
   );

   printf 'Searching MetaCPAN for distributions via "%-28s"...', 'Dist-Zilla-*';
   my $details = $MCPAN->fetch( "release/_search", %search_params );
   @distros = uniq( @distros, map { $_->{fields}{distribution} } @{ $details->{hits}{hits} } );
   map { $distro_author{ $_->{fields}{distribution} } = $_->{fields}{author} } @{ $details->{hits}{hits} };
   printf 'found %3u hits (up to %3u distros total)'."\n", $details->{hits}{total}, scalar @distros;

   # Now, run through each of those to get the individual module names
   my @core;
   my %plugin_author;  ### LAZY
   foreach my $distro (sort grep { not $_ ~~ @BLACKLIST_DISTRO } @distros) {
      %search_params = (
         q      => join(' AND ', 'distribution:"'.$distro.'"', 'status:latest', 'module.authorized:true'),
         fields => 'module.name',
         size   => 5000,
      );

      printf 'Searching MetaCPAN for modules in distribution:"%-50s"...', $distro;
      my $details = $MCPAN->fetch( "file/_search", %search_params );
      my @new_plugins =
         uniq
         grep { not $_ ~~ @BLACKLIST_PLUGIN }
         map  { plugin_name($_) }
         grep { not $_ ~~ @BLACKLIST_CLASS  }
         grep { not $_ ~~ @EXISTING_CLASS   }
         map  {
            my $n = $_->{fields}{'module.name'};
            ref $n ? @$n : $n;
         }
         @{ $details->{hits}{hits} }
      ;
      printf 'found %2u hits (with %2u new modules)'."\n", $details->{hits}{total}, scalar @new_plugins;

      push @NEW, @new_plugins;
      @core = @new_plugins if ($distro eq 'Dist-Zilla');
      map { $plugin_author{$_} = $distro_author{$distro} } @new_plugins;
   }

   # Finally, we'll get some more details for these new modules
   @NEW = uniq sort @NEW;
   my @new_details;
   my $ua = $MCPAN->ua->mechua;  # the source files aren't JSON, so we need the main UA
   foreach my $plugin (@NEW) {
      my $class = plugin_class($plugin);
      my @tags;

      printf "Scanning source file for %-50s...", $plugin;
      my $src = $ua->get( $MCPAN->base_url . "/source/$class" )->content;

      my $doc = Pod::Elemental->read_string($src);
      Pod::Elemental::Transformer::Pod5->new->transform_node($doc);
      
      # Find the DESCRIPTION/ABSTRACT header and get the next block down
      my $dc = $doc->children;
      my $di = -1;
      my $description = '';
      foreach my $section (qw{DESCRIPTION ABSTRACT NAME}) {
         $di = firstidx {
            $_->isa($POD5.'::Command') &&
            $_->command eq 'head1' && $_->content eq $section
         } @$dc;
         next unless ( $dc->[$di+1]->isa($POD5.'::Ordinary') );
         last if ($di > -1);
      }
      if ($di > -1) {
         $description =  $dc->[$di+1]->content;
         $description =~ s/^\Q$class - \E//;
         $description =~ s/\s+/ /g;
         $description =  ucfirst $description;

         if ($description =~ /:\s*$/) {
            $description .= "\n\n".$dc->[$di+2]->as_pod_string;
         }
         elsif ($dc->[$di+2] && $dc->[$di+2]->isa($POD5.'::Ordinary')) {
            my $content = $dc->[$di+2]->content;
            $content =~ s/\s+/ /g;
            $description .= "\n$content";
         }
      }

      print "done\n";

      # Role sorting
      for ($plugin) {
         when (/^\@/) { @tags = ('bundle');  }
         when (/^\>/) { @tags = ('command'); }
         when (/^\=/) { die "??!?";          }
         default      {
            my $code;
            #PAR::Filter->new('PodStrip', 'Squish')->apply(\$code);
            my $ps = Pod::Strip->new;
            $ps->output_string(\$code);
            $ps->parse_string_document($src);

            while ($code =~ /^\s*with[\s\(]([^\;]+)\;/gm) {
               my $with_section = $1;
               while ($with_section =~ /Dist::Zilla::Role::([\w:]+)/g) {
                  my $tag = $ROLE2TAG{$1};
                  #print "\nROLE = $1 --> $tag\n";
                  push @tags, $tag if $tag;
               }
            }
         }
      }

      # Further tag processing
      push @tags, 'git'             if ($plugin =~ /Git(?:[^a-z]|$)/);
      push @tags, 'changelog'       if ($plugin =~ /Change[lL]og(?:[^a-z]|$)/);
      push @tags, 'documentation'   if ($plugin =~ /Pod(?:[^a-z]|$)/);
      push @tags, 'manifest'        if ($plugin =~ /Manifest(?:[^a-z]|$)/);
      push @tags, 'metadata'        if ($plugin =~ /Meta(?:[^a-z]|$)/);
      push @tags, 'tests'           if ($plugin =~ /Tests?(?:[^a-z]|$)/);
      push @tags, 'version'         if ($plugin =~ /Version(?:[^a-z]|$)/);
      push @tags, 'version-control' if ($plugin =~ /(Subversion|SV[NK]|CVS|Mercurial)(?:[^a-z]|$)/);

      push @tags, 'core'            if ($plugin ~~ @core);
      push @tags, 'version-control' if ('git' ~~ @tags);

      # XXX: No checks for 'for-subclassing', 'tests-extra', or 'version-insert'

      push @new_details, [ $plugin, $plugin_author{$plugin}, $description, join(' ', uniq sort @tags) ];
   }
   @NEW = @new_details;
   print "\nFound ".@NEW." new plugins!\n\n";
}

# Ripped (mostly) from Dist::Zilla::Role::MetaCPANInterfacer
sub _mcpan_set_agent_str {
   my ($ua) = @_;
   my $o = ucfirst($^O);

   use POSIX;
   my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
   my $os = join('; ', "$sysname $release", $machine, $version);

   $ua->agent("Mozilla/5.0 ($o; $os) dzil.org/find-plugins.pl ".$ua->_agent);

   return $ua;
}
