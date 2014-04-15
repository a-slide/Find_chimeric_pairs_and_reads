#! /bin/bash

#  chimera_finder_pair.sh
#
#  Copyright 2014 adrien <adrien.leger@gmail.com>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.

# Export environment parameters
export LC_ALL=C

    ####################################################################################################################
    # Help function
    ####################################################################################################################
    help()
    {
        echo -e " \nChecking the number or arguments ... "
        if [[ $1 != 6 ]]; then
            echo -e "Usage: chimera_finder_pair\n\
            \t<R1.fastq.gz>\n\
            \t<R2.fastq.gz>\n\
            \t<output name>\n\
            \t<ref1 bowtie2 index>\n\
            \t<ref2 bowtie2 index>\n\
            \t<ref1+2 bowtie2 index>\n"
            exit 1
        else
            echo -e "Correct number of arguments\n"
        fi
    }

    ####################################################################################################################
    # Checking dependencies installation
    ####################################################################################################################
    dependencies()
    {
        echo -e "Checking the number or dependencies...\n"
        if [ "$(which bowtie2)" == "" ] ; then
            echo "Intall Bowtie2 and/or add it to your PATH."
            exit 1
        fi

        if [ "$(which samtools)" == "" ] ; then
            echo "Intall samtools and/or add it to your PATH."
            exit 1
        fi

        if [ "$(which bedtools)" == "" ]; then
            echo "Intall bedtools and/or add it to your PATH."
            exit 1
        fi

        if [ "$(which sickle)" == "" ]; then
            echo "Intall sickle and/or add it to your PATH."
            exit 1
        fi
        echo -e "Correct number of dependencies\n"
    }

    ####################################################################################################################
    # Preprocessing of fastq files with sickle
    ####################################################################################################################
    preprocess(){

        # 1 = R1.fastq.gz
        # 2 = R2.fastq.gz
        # 3 = output R1 paired
        # 4 = output R2 paired
        # 5 = output orphan reads

        # Trimming ends until the quality is > 30 for 100 bp long (can be ajusted)
        echo -e "\nTrimming bad quality sequences...\n"
        sickle pe -f "$1" -r "$2" -o "$3" -p "$4" -s "$5" -t sanger -q 30 -l 100
    }

    ####################################################################################################################
    # End to end mapping against a reference and keeping only
    ####################################################################################################################
    unmap_pair() {

        # 1 = index
        # 2 = R1
        # 3 = R2
        # 4 = output

        echo -e "\nEnd to end mapping with Bowtie2 against "$1"...\n"
        bowtie2 --end-to-end --very-sensitive --mp 40 -p 4 --reorder -x "$1" -1 "$2" -2 "$3" -S "$4".sam

        echo -e "\nConverting SAM output in sorted BAM file with Samtools...\n"
        samtools view -hbS "$4".sam | samtools sort - "$4"

        echo -e "\nExtracting unmapped reads with Samtools...\n"
        samtools view -uh -f 4 -F 264 "$4".bam > 1.bam &
        samtools view -uh -f 8 -F 260 "$4".bam > 2.bam &
        samtools view -uh -f 12 -F 256 "$4".bam > 3.bam
        wait
        samtools merge -u - [123].bam | samtools sort -n - "$4"_unmapped

        echo -e "\nDeinterlacing read R1 and R2 and Converting BAM to fastq..."
        samtools view -uh -f 64 "$4"_unmapped.bam > R1.bam &
        samtools view -uh -f 128 "$4"_unmapped.bam > R2.bam
        wait
        bedtools bamtofastq -i R1.bam -fq "$4"_R1.fastq &
        bedtools bamtofastq -i R2.bam -fq "$4"_R2.fastq
        wait

        rm -f [123].bam R[12].bam
    }

    ####################################################################################################################
    # Local mapping against both reference and extracting chimeric pairs
    ####################################################################################################################
    extract_chimeric() {

        # 1 = index
        # 2 = R1
        # 3 = R2
        # 4 = output
        # 5 = Motif_ref1_(ex:AAV)
        # 6 = Motif_ref2_(ex:chr)

        echo -e "\n\tLocal alignment against both reference index with bowtie2...\n"
        bowtie2 --very-sensitive-local --mp 40 -p 4 --reorder -x "$1" -1 "$2" -2 "$3" -S "$4".sam

        echo -e "\nConverting SAM output in sorted BAM file...\n"
        samtools view -hbS "$4".sam | samtools sort - "$4"

        echo -e "\nRemoving reads unmapped, with MAPQ < 30 and PCR duplicates...\n"
        samtools view -h -F 260 -q 30 -b "$4".bam | samtools rmdup - "$4"_mapped.bam

        echo -e "\nConverting BAM to SAM..."
        samtools view -h "$4"_mapped.bam > "$4"_mapped.sam

        echo -e "\nExtracting pairs whose mates are aligned to "$5" and "$6"..."

        # extracting sam header and sorting
        grep '^@' "$4"_mapped.sam > "$4"_final.sam
        sort "$4"_mapped.sam > "$4"_sorted.sam

        # Searching for reads containing motif 1 and extracting the name + same thing for ref 2
        awk -v motif="$5" '$3 ~ motif {print $1}' "$4"_sorted.sam > "$5".txt &
        awk -v motif="$6" '$3 ~ motif {print $1}' "$4"_sorted.sam > "$6".txt
        wait

        # Generating a sam file of reads containing both references
        comm -12 "$5".txt "$6".txt > "$5"_"$6"_intersect.txt
        join -t $'\t' "$5"_"$6"_intersect.txt "$4"_sorted.sam >> "$4"_final.sam
    }

    ####################################################################################################################
    # Create BAM index and Bed graph file needed for data visualization with IGV
    ####################################################################################################################
    generate_coverage() {

        # 1 = SAM file containing chimeric reads
        # 2 = output name

        echo -e "\n\t Prepararing coverage visualisation files...\n"

        # Moving the SAM file containing chimeric reads to the current folder
        mv "$1" ./"$2".sam

        # Convert the SAM to BAM
        samtools view -hbS "$2".sam | samtools sort - "$2"

        # Preparing files for visualization with IGV
        samtools index "$2".bam &
        genomeCoverageBed -ibam "$2".bam -bg -trackline -trackopts "name="$2" color=250,0,0" > "$2".bedGraph

        # Depth filtering can be achieved by using the following line instead
        # genomeCoverageBed -ibam "$2".bam -bg -trackline -trackopts "name="$2" color=250,0,0" | awk '$4 > 1'> "$2".bedGraph

        wait
    }

    ####################################################################################################################
    # Generate a report summarizing mapping steps
    ####################################################################################################################

    generate_report() {

        # 1 = R1.fastq.gz
        # 2 = R2.fastq.gz
        # 3 = output name
        # 4 = ref1 bowtie2 index
        # 5 = ref2 bowtie2 index
        # 6 = ref1+2 bowtie2 index

        echo -e "\n\tGenerating a report"

        # Storing dates and arguments parameters
        date > "$3"_report.txt
        echo -e "Arguments used :\n\
        R1.fastq.gz : "$1"\n\
        R2.fastq.gz : "$2"\n\
        output name : "$3"\n\
        ref1 bowtie2 index : "$4"\n\
        ref2 bowtie2 index : "$5"\n\
        ref1+2 bowtie2 index : "$6"\n" >> "$3"_report.txt

        # Generating Bam Flagstat
        echo -e "\n\tRef 1 Raw mapping\n" >> "$3"_report.txt
        samtools flagstat ../02-substract/"$3"_1.bam  >> "$3"_report.txt
        echo -e "\n\tRef 1 Unmapped sequences\n" >> "$3"_report.txt
        samtools flagstat ../02-substract/"$3"_1_unmapped.bam  >> "$3"_report.txt

        echo -e "\n\tRef 2 Raw mapping\n" >> "$3"_report.txt
        samtools flagstat ../02-substract/"$3"_2.bam  >> "$3"_report.txt
        echo -e "\n\tRef 2 Unmapped sequences\n" >> "$3"_report.txt
        samtools flagstat ../02-substract/"$3"_2_unmapped.bam  >> "$3"_report.txt

        echo -e "\n\tRef 3 Raw mapping\n" >> "$3"_report.txt
        samtools flagstat ../03-extract/"$3".bam >> "$3"_report.txt
        echo -e "\n\tRef 3 Mapped sequence only\n" >> "$3"_report.txt
        samtools flagstat ../03-extract/"$3"_mapped.bam >> "$3"_report.txt
        echo -e "\n\tRef 3 Final result\n" >> "$3"_report.txt
        samtools flagstat "$3".bam >> "$3"_report.txt
    }

    ####################################################################################################################
    # MAIN SCRIPT
    ####################################################################################################################

    # 1 = R1.fastq.gz
    # 2 = R2.fastq.gz
    # 3 = output name
    # 4 = ref1 bowtie2 index
    # 5 = ref2 bowtie2 index
    # 6 = ref1+2 bowtie2 index

    # CHECKING THE NUMBER OF ARGS AND DEPENDENCIES
    help "$#"
    dependencies

    # PRE PROCESSING
    mkdir -p 01-preprocess
    cd 01-preprocess
    preprocess ../"$1" ../"$2" "$3"_trim_R1.fastq "$3"_trim_R2.fastq "$3"_trim_single.fastq
    cd ..

    # STEP OF ALIGNMENT VS REF1 AND EXTRACTION OF UNMAPPED READS AND SAME THING WITH REF2
    mkdir -p 02-substract
    cd 02-substract
    # Mappping against first ref index
    unmap_pair ../$4 ../01-preprocess/"$3"_trim_R1.fastq ../01-preprocess/"$3"_trim_R2.fastq "$3"_1
    # Mapping against second ref index
    unmap_pair ../$5 "$3"_1_R1.fastq "$3"_1_R2.fastq "$3"_2
    cd ..

    #LOCAL ALIGNMENT VS BOTH REF AND EXTRACTION OF MAPPED READS USING BOWTIE
    mkdir -p 03-extract
    cd 03-extract
    # Motifs can be changed to be adapted to specific patterns (in this case AAV and chr)
    extract_chimeric ../"$6" ../02-substract/"$3"_2_R1.fastq ../02-substract/"$3"_2_R2.fastq "$3" "AAV" "chr"
    cd ..

    # Creating bam and bedgraphs for visualisation with igv
    mkdir -p 04-final
    cd 04-final
    generate_coverage ../03-extract/"$3"_final.sam "$3"
    generate_report "$1" "$2" "$3" "$4" "$5" "$6"
    cd ..

    exit 0
