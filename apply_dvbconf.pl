#!/usr/bin/perl

# dvbv5-zap 向けの設定ファイル
# https://github.com/Chinachu/dvbconf-for-isdb
# から
# recdvb のチャンネルテーブルへデータぶっ込む

use utf8;
use strict;
use Data::Dumper;
use File::Path 'rmtree';
use Encode;

exit(main());

sub split_ch_name {
    my($ch) = @_;
    $ch =~ /(BS|CS)([\d]+)(|_[\d]+)/;
    return {
        type => $1,
        no => int($2),
        add => int($3),
    };
}
sub cmp_split_ch_name {
    my($a, $b) = @_;
    if($a->{type} eq $b->{type}) {
        if($a->{no} == $b->{no}) {
            return $a->{add} <=> $b->{add};
        }
        else {
            return $a->{no} <=> $b->{no};
        }
    }
    else {
        return $a->{type} cmp $b->{type};
    }
}

sub main {
    my $tmp_dir = '_tmp_';
    print("remove $tmp_dir\n");
    rmtree($tmp_dir);
    print("mkdir $tmp_dir\n");
    mkdir($tmp_dir) || die 'mkdir error';
    print("download\n");
    my $conf_filename = "$tmp_dir/dvbv5_channels_isdbs.conf";
    my $ret = system("curl -o $conf_filename https://raw.githubusercontent.com/Chinachu/dvbconf-for-isdb/master/conf/dvbv5_channels_isdbs.conf");
    print("ret=$ret\n");
    if($ret) {
        die "error download";
    }

    print("parse data\n");
    my @datas;
# [BS01_0]
# 	DELIVERY_SYSTEM = ISDBS
# 	FREQUENCY = 1049480
# 	STREAM_ID = 16400
    my @lines;
    {
        open(my $fh, $conf_filename) || die "open error $conf_filename";
        @lines = <$fh>;
        close($fh);
    }
    my $cur;
    foreach my $line (@lines) {
        if($line =~ /\[(.+?)\]/) {
            my $ch = $1;
            if($cur) {
                push(@datas, $cur);
            }
            $cur = {ch => $ch};
        }
        elsif($line =~ /^\s*([^\s]+)\s*=\s*([^\s]+)/) {
            my $k = $1;
            my $v = $2;
            $cur->{$k} = $v;
        }
    }
    if($cur) {
        push(@datas, $cur);
    }
    # 抜け
    # このへんはちゃんと含まれているはず
    # BS01_1(16401) # BS-TBS 0x4011
    # BS01_2(16402) # BSテレ東 0x4012
    # BS03_0(16432) # WOWOWプライム 0x4030
    # BS05_0(17488) # WOWOWライブ 0x4450
    # BS05_1(17489) # WOWOWシネマ 0x4451
    # BS09_1(16529) # スターチャンネル1 0x4091
    # BS09_0(16528) # BS11イレブン 0x4090
    # BS09_2(16530) # BS12トゥエルビ 0x4092
    # BS21_2(18258) # グリーンチャンネル 0x4752
    push(@datas, {ch => 'BS11_3', STREAM_ID => '18099'});   # 釣りビジョン

    # BS0x_x を BSx_x のようにゼロパディング抜く
    @datas = map{
        my $ch = $_->{ch};
        $ch =~ s/^BS0/BS/;
        $_->{ch} = $ch;
        $_;
    } @datas;

        # 抜けているチャンネル補填
    my @all_chs = qw/
BS1_0
BS1_1
BS1_2
BS1_3
BS3_0
BS3_1
BS3_2
BS3_3
BS5_0
BS5_1
BS5_2
BS5_3
BS7_0
BS7_1
BS7_2
BS7_3
BS9_0
BS9_1
BS9_2
BS9_3
BS11_0
BS11_1
BS11_2
BS11_3
BS13_0
BS13_1
BS13_2
BS13_3
BS15_0
BS15_1
BS15_2
BS15_3
BS17_0
BS17_1
BS17_2
BS17_3
BS19_0
BS19_1
BS19_2
BS19_3
BS21_0
BS21_1
BS21_2
BS21_3
BS23_0
BS23_1
BS23_2
BS23_3
        /;
    my %ch_hash = map{$_->{ch}=>1} @datas;
    foreach my $ch (@all_chs) {
        if(!exists($ch_hash{$ch})) {
            # ダミーなので内容は適当
            push(@datas, {
                ch => $ch,
                DELIVERY_SYSTEM => 'ISDBS',
                FREQUENCY => '1049480',
                STREAM_ID => '0',
            });
        }
    }

    @datas = sort{
        cmp_split_ch_name(
            split_ch_name($a->{ch}),
            split_ch_name($b->{ch})
        );
    } @datas;

    #print(Dumper(\@datas));
    printf("extract %d datas\n", scalar(@datas));

#  set_freq, type, add_freq, tsid, parm_freq
# {   0, CHTYPE_SATELLITE, 0, 0x4010, "151"},  /* 151ch：BS朝日 */
# add_freq が実際に使えれば良いのだが、どういうわけか dvb 版は tsid でチューニングするらしい
# parm_freq は BS では本来のチャンネル番号指定としては使わない前提でBSxx_xに、CS では使用するので CSxx を入れる
# set_freq は BSxx の xx / 2 になる

    print("convert C source\n");
    my @dst_lines;
    foreach my $data (@datas) {
        my $ch = $data->{ch};
        my $tsid = int($data->{STREAM_ID});
        my $freq;
        my $slot;
        if($ch =~ /^BS(\d+)_(\d+)/) {
            $freq = int($1);
            $slot = int($2);
            $freq = int($freq / 2);

        }
        elsif($ch =~ /CS(\d+)/) {
            $freq = int($1);
            # CS2 → 12
            # CS4 → 13
            $freq = $freq/2 + 11;
            $slot = 0;
        }
        push(@dst_lines, sprintf(qq/{%4d, CHTYPE_SATELLITE, %d, 0x%04x, "%s"}/, $freq, $slot, $tsid, $ch));
    }

    print("read original source\n");
    my $src;
    {
        open(my $fh, 'pt1_dev.h.orig') || die "open error";
        local $/;
        $src = <$fh>;
        close($fh);
    }

    print("apply generated code\n");
    my $data_txt = join('', map{'    ' . $_ . ',' . "\n"} @dst_lines);
    $src =~ s!// <<<< dvbconf data >>>>!$data_txt!m;

    print("write source\n");
    open(my $fh, '>', 'pt1_dev.h') || die "open error";
    print $fh $src;
    close($fh);

    # ついでに Mirakurun チャンネルリストも
    print("generate channel.yml\n");
    my @ch_lines;
    push(@ch_lines, "# GENERATED BY apply_dvbconf.pl");
    push(@ch_lines, '');
    push(@ch_lines, "######## GR ########");
    foreach my $no (1..62) {
# - name: '1'
#   type: GR
#   channel: '1'
        push(@ch_lines, "- name: '$no'");
        push(@ch_lines, "  type: GR");
        push(@ch_lines, "  channel: '$no'");
    }
    # CATV は使っていないので
    if(0) {
        push(@ch_lines, '');
        push(@ch_lines, "######## CATV ########");
        foreach my $no (13..63) {
# - name: 'C13'
#   type: GR
#   channel: 'C13'
            push(@ch_lines, "- name: 'C$no'");
            push(@ch_lines, "  type: GR");
            push(@ch_lines, "  channel: 'C$no'");
        }
    }

    push(@ch_lines, '');
    push(@ch_lines, "######## BS ########");
    foreach my $data (@datas) {
# - name: 'BS1_0'
#   type: BS
#   channel: 'BS1_0'
        if($data->{ch} =~ /^BS/) {
            push(@ch_lines, "- name: '$data->{ch}'");
            push(@ch_lines, "  type: BS");
            push(@ch_lines, "  channel: '$data->{ch}'");
        }
    }

    push(@ch_lines, '');
    push(@ch_lines, "######## CS ########");
    foreach my $data (@datas) {
# - name: 'CS2'
#   type: CS
#   channel: 'CS2'
        if($data->{ch} =~ /^CS/) {
            push(@ch_lines, "- name: '$data->{ch}'");
            push(@ch_lines, "  type: CS");
            push(@ch_lines, "  channel: '$data->{ch}'");
        }
    }

    push(@ch_lines, '');
    push(@ch_lines, "# EOF");

    open(my $fh, '>'. 'channels.yml') || die "open error";
    print $fh join("\n", @ch_lines);
    close($fh);

    return 0;
}
