# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

use strict;
use warnings;
use DynaLoader;

my $library = DynaLoader::dl_load_file($ARGV[0], 0) or exit 2;
my $symbol = DynaLoader::dl_find_symbol($library, "omni_now_playing_run") or exit 3;
my $run = DynaLoader::dl_install_xsub("OmniWM::NowPlaying::run", $symbol);
&$run();
