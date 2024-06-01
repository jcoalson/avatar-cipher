# To test, try
#
#   printf "Hello\nworld" | gnumake && ls output/
#

output/example.png: output/example.pbm
	convert $< -strip $@

output/example.pbm: encode.pl hint-110010.pbm secret.txt font-5x5.txt
	mkdir -p $(@D)
	./$< -H $(filter-out $<,$^) $@

secret.txt:
	printf "1\n1\n0\n0\n1\n0\n" > $@

clean:
	rm secret.txt
