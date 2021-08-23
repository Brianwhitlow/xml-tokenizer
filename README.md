# xml-tokenizer
I thought about trying to make something to generate zig code from vk.xml as a hobby project, but found there wasn't
any readily available no-heap XML parsers/tokenizers, so I decided to make my own. First time making something like this,
so any suggestions to improve it would be great, but I don't expect this to become anything serious, especially since
zig hasn't even reached 1.0 yet.
It isn't quite finished yet, since it still can't tokenize CDATA sections, or any of the DOCTYPE markup sections, but
can eat through anything else.
