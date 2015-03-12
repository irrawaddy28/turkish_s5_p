#!/bin/bash

# Copyright 2012-2014  Brno University of Technology (Author: Karel Vesely)
# Apache 2.0

# This example script trains a DNN on top of fMLLR features. 
# The training is done in 3 stages,
#
# 1) RBM pre-training:
#    in this unsupervised stage we train stack of RBMs, 
#    a good starting point for frame cross-entropy trainig.
# 2) frame cross-entropy training:
#    the objective is to classify frames to correct pdfs.
# 3) sequence-training optimizing sMBR: 
#    the objective is to emphasize state-sequences with better 
#    frame accuracy w.r.t. reference alignment.

. ./cmd.sh ## You'll want to change cmd.sh to something that will work on your system.
           ## This relates to the queue.

. ./path.sh ## Source the tools/utils (import the queue.pl)

echo "$0 $@"  # Print the command line for logging

stage=0 # resume training with --stage=N
max_nj_decode=10 
transform_dir=
#precomp_feat_transform=
precomp_dbn=
# End of config.
[ -f ./path.sh ] && . ./path.sh; # source the path.
. utils/parse_options.sh || exit 1;
#

if [ $# != 2 ]; then   
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --transform-dir <transform-dir>                  # where to find fMLLR transforms."
   #echo "  --precomp-feat-transform <pre-computed feature transform> # pre-computed feature transform that can be used for DNN training "
   echo "  --precomp-dbn <pre-computed dbn dir> # pre-computed dbn dir that can be used for DNN training"
   exit 1;
fi

# Config:
gmmdir=$1  #exp/tri3
num_trn_utt=$2
data_fmllr=data-fmllr-tri1${num_trn_utt}  #data-fmllr-tri3
echo "user i/p fMMLR transform dir = $transform_dir";


if [ $stage -le 0 ]; then
  # Store fMLLR features, so we can train on them easily,
  # test  
  dir=$data_fmllr/test
  [[ ! -z $transform_dir ]] && transform_dir_opt="--transform-dir $transform_dir/decode_test" || transform_dir_opt=""
  steps/nnet/make_fmllr_feats.sh --nj 10 --cmd "$train_cmd" \
     $transform_dir_opt \
     $dir data/test $gmmdir $dir/log $dir/data || exit 1
  # dev
  dir=$data_fmllr/dev
  [[ ! -z $transform_dir ]] && transform_dir_opt="--transform-dir $transform_dir/decode_dev" || transform_dir_opt=""
  steps/nnet/make_fmllr_feats.sh --nj 5 --cmd "$train_cmd" \
     $transform_dir_opt \
     $dir data/dev $gmmdir $dir/log $dir/data || exit 1
  # train
  dir=$data_fmllr/train
  [[ ! -z $transform_dir ]] && transform_dir_opt="--transform-dir ${transform_dir}_ali" || transform_dir_opt=""
  steps/nnet/make_fmllr_feats.sh --nj 10 --cmd "$train_cmd" \
     $transform_dir_opt \
     $dir data/train${num_trn_utt} $gmmdir $dir/log $dir/data || exit 1
  # split the data : 90% train 10% cross-validation (held-out)
  utils/subset_data_dir_tr_cv.sh $dir ${dir}_tr90 ${dir}_cv10 || exit 1
fi

if [ $stage -le 1 ]; then
  if [[ -z ${precomp_dbn} ]]; then 
  # Pre-train DBN, i.e. a stack of RBMs (small database, smaller DNN)
  dir=exp/dnn4_pretrain-dbn${num_trn_utt}
  (tail --pid=$$ -F $dir/log/pretrain_dbn.log 2>/dev/null)& # forward log
  $cuda_cmd $dir/log/pretrain_dbn.log \
    steps/nnet/pretrain_dbn.sh --hid-dim 1024 --rbm-iter 20 $data_fmllr/train $dir || exit 1;
  else
  [[ ! -d ${precomp_dbn} ]] && echo "pre-computed dbn directory ${precomp_dbn} does not exist"
  echo "using pre-computed dbn from ${precomp_dbn}"
  dir=exp/dnn4_pretrain-dbn${num_trn_utt}
  mkdir -p $dir
  cp -r ${precomp_dbn}/* $dir
  fi
fi

if [ $stage -le 2 ]; then
  # Train the DNN optimizing per-frame cross-entropy.
  dir=exp/dnn4_pretrain-dbn_dnn${num_trn_utt}
  ali=${gmmdir}_ali
  feature_transform=exp/dnn4_pretrain-dbn${num_trn_utt}/final.feature_transform
  dbn=exp/dnn4_pretrain-dbn${num_trn_utt}/6.dbn
  (tail --pid=$$ -F $dir/log/train_nnet.log 2>/dev/null)& # forward log
  # Train
  $cuda_cmd $dir/log/train_nnet.log \
    steps/nnet/train.sh --feature-transform $feature_transform --dbn $dbn --hid-layers 0 --learn-rate 0.008 \
    $data_fmllr/train_tr90 $data_fmllr/train_cv10 data/lang $ali $ali $dir || exit 1;
  # Decode (reuse HCLG graph)
  nj_decode=$(cat conf/dev_spk.list |wc -l); [[ $nj_decode -gt  $max_nj_decode ]] && nj_decode=$max_nj_decode;  
  steps/nnet/decode.sh --nj $nj_decode --cmd "$decode_cmd" --acwt 0.2 \
    $gmmdir/graph $data_fmllr/dev $dir/decode_dev || exit 1;    
  nj_decode=$(cat conf/test_spk.list |wc -l); [[ $nj_decode -gt  $max_nj_decode ]] && nj_decode=$max_nj_decode; 
  steps/nnet/decode.sh --nj $nj_decode --cmd "$decode_cmd" --acwt 0.2 \
    $gmmdir/graph $data_fmllr/test $dir/decode_test || exit 1;  
fi


## Sequence training using sMBR criterion, we do Stochastic-GD 
## with per-utterance updates. We use usually good acwt 0.1
#dir=exp/dnn4_pretrain-dbn_dnn_smbr
#srcdir=exp/dnn4_pretrain-dbn_dnn
#acwt=0.2

#if [ $stage -le 3 ]; then
  ## First we generate lattices and alignments:
  #steps/nnet/align.sh --nj 20 --cmd "$train_cmd" \
    #$data_fmllr/train data/lang $srcdir ${srcdir}_ali || exit 1;
  #steps/nnet/make_denlats.sh --nj 20 --cmd "$decode_cmd" --acwt $acwt \
    #--lattice-beam 10.0 --beam 18.0 \
    #$data_fmllr/train data/lang $srcdir ${srcdir}_denlats || exit 1;
#fi

#if [ $stage -le 4 ]; then
  ## Re-train the DNN by 6 iterations of sMBR 
  #steps/nnet/train_mpe.sh --cmd "$cuda_cmd" --num-iters 6 --acwt $acwt \
    #--do-smbr true --use-silphones true \
    #$data_fmllr/train data/lang $srcdir ${srcdir}_ali ${srcdir}_denlats $dir || exit 1
  ## Decode
  #for ITER in 1 6; do
    #steps/nnet/decode.sh --nj 20 --cmd "$decode_cmd" \
      #--nnet $dir/${ITER}.nnet --acwt $acwt \
      #$gmmdir/graph $data_fmllr/test $dir/decode_test_it${ITER} || exit 1
    #steps/nnet/decode.sh --nj 20 --cmd "$decode_cmd" \
      #--nnet $dir/${ITER}.nnet --acwt $acwt \
      #$gmmdir/graph $data_fmllr/dev $dir/decode_dev_it${ITER} || exit 1
  #done 
#fi

echo Success
exit 0

# Getting results [see RESULTS file]
# for x in exp/*/decode*; do [ -d $x ] && grep WER $x/wer_* | utils/best_wer.sh; done
