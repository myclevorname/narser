
output=_narser.bash

cmd=narser
cmd_opts=(-h -?)

subcmds=(hash cat ls pack unpack)

subcmd_args_hash='@files'
subcmd_opts_hash=(-h -? -x)

subcmd_args_ls='@files'
subcmd_opts_ls=(-l -L -r -R -h -?)

subcmd_args_unpack='@files'
subcmd_opts_unpack=(-? -h)

subcmd_comp_alias=(
	['pack']=hash
	['cat']=unpack
)
