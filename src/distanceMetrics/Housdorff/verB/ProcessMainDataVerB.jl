module ProcessMainDataVerB
using CUDA, Logging,Main.CUDAGpuUtils,Main.WorkQueueUtils, Logging,StaticArrays, Main.IterationUtils, Main.ReductionUtils, Main.CUDAAtomicUtils,Main.MetaDataUtils
export calculateLoopsIter,@processMaskData




"""
we need to establish is the block full after dilatation step 
"""
macro establishIsFull()
    return esc(quote
    @redWitAct(offsetIter,shmemSum,  isMaskFull,& )
    sync_threads()
    #now if it evaluated to 1 we should save it to metadata 
    @ifXY 1 1 setBlockAsFull(metaData,linIndex, isGoldPass)
end)
end#establishIsFull




                
"""
 validates data is of our intrest               
"""                
macro validateData()
    return esc(quote
    @iter3dW  dataBlockDims loopX loopY loopZ blockBeginingX blockBeginingY blockBeginingZ resShemVal begin
        locVal::Bool = @inbounds  (locArr>>(zIter-1) & 1)
        resShemVal::Bool = @inbounds resShmem[threadIdxX()+1,threadIdxY()+1,zIter+1]             
        locValOrShmem = (locVal | resShemVal)
        #those needed to establish weather data block will remain active
        isMaskFull= locValOrShmem & isMaskFull
        if(!locVal && resShemVal)       
              innerValidate(analyzedArr,referenceArray,x,y,z,privateResArray,privateResCounter,iterationnumber,sourceShmem  )
        end#if
     end#3d iter 
    end)
    
 end  #validateData                  

"""
this will be invoked when we know that we have a true in a spot that was false before this dilatation step and its task is to set to true appropriate spot in global array
- so proper dilatation
check weather we have true also in reference array - if so we  need to add this spot to the block result list in case we are invoke it from padding we need to look even futher into the
next block data to establish could this spot be activated from there
"""
  function innerValidate(analyzedArr,referenceArray,x,y,z,privateResArray,privateResCounter,iterationnumber,sourceShmem  )
            # setting value in global memory
            @inbounds  analyzedArr[x,y,z]= true
            # if we are here we have some voxel that was false in a primary mask and is becoming now true - if it is additionaly true in reference we need to add it to result
    
            if(@inbounds referenceArray[x,y,z])
                #results now are stored in a matrix where first 3 entries are x,y,z coordinates entry 4 is in which iteration we covered it and entry 5 from which direction - this will be used if needed        
                #privateResCounter privateResArray are holding in metadata blocks results and counter how many results were already added 
                #in each thread block we will have separate rescounter, and res array for goldboolpass and other pass
               direction=  getDir(sourceShmem)   
               appendResultMainPart(metaData, linIndex, x,y,z,iterationnumber, direction)
            end#if
  end#innerValidate 
     



# """
# Help to establish should we validate the voxel - so if ok add to result set, update the main array etc
#   in case we have some true in padding
#   generally we need just to get idea if
#     we already had true in this very spot - if so we ignore it
#     can this spot be reached by other voxels from the block we are reaching into - in other words padding is analyzing the same data as other block is analyzing in its main part
#       hence if the block that is doing it in main part will reach this spot on its own we will ignore value from padding 

#   in order to reduce sears direction by 1 it would be also beneficial to know from where we had came - from what direction the block we are spilled into padding 
# """
# function isPaddingValToBeValidated(dir,analyzedArr, x,y,z )::Bool
     
# if(dir!=5)  if( @inbounds resShmem[threadIdxX(),threadIdxY(),zIter-1]) return false  end end #up
# if(dir!=6)  if( @inbounds  resShmem[threadIdxX(),threadIdxY(),zIter+1]) return false  end  end #down
    
# if(dir!=1)   if( @inbounds  resShmem[threadIdxX()-1,threadIdxY(),zIter]) return false  end  end #left
# if(dir!=2)   if( @inbounds   resShmem[threadIdxX()+1,threadIdxY(),zIter]) return false  end end  #right

# if(dir!=4)   if(  @inbounds  resShmem[threadIdxX(),threadIdxY()+1,zIter]) return false  end  end #front
# if(dir!=3)   if( @inbounds  resShmem[threadIdxX(),threadIdxY()-1,zIter]) return false  end end  #back
#   #will return true only in case there is nothing around 
#   return true
# end


"""
uploaded data from shared memory in amask of intrest gets processed in this function so we need to  
    - save it to registers (to locArr)
    - save to the 6 surrounding voxels in shared memory intermediate results 
            - as we also have padding we generally start from spot 2,2 as up and to the left we have 1 padding
            - also we need to make sure that in corner cases we are getting to correct spot
"""
macro processMaskData( maskBool) #::CUDA.CuRefValue{Int32}
    # save it to registers - we will need it later
    #locArr[zIter]=maskBool
    #now we are saving results evrywhere we are intrested in so around without diagonals (we use supremum norm instead of euclidean)
    #locArr.x|= maskBool << zIter
    return esc(quote
        if($maskBool)
            sourceShmem[xpos,ypos, zpos]= true          

            @inbounds resShmem[xpos+1,ypos+1,zpos]=true #up
            @inbounds resShmem[xpos+1,ypos+1,zpos+2]=true #down
        
            @inbounds  resShmem[xpos,ypos+1,zpos+1]=true #left
            @inbounds  resShmem[xpos+2,ypos+1,zpos+1]=true #right

            @inbounds  resShmem[xpos+1,ypos+2,zpos+1]=true #front
            @inbounds  resShmem[xpos+1,ypos,zpos+1]=true #back
        end#if    
    end)
end#processMaskData


"""
   loads main values from analyzed array into shared memory and to locArr - which live in registers   
   it all works under the assumption that x and y dimension of the thread block and data block is the same           
"""                
                
macro loadMainValues(mainArrGPU)
    return esc(quote
    @iterDataBlock(mainArrDims,datBdim, inBlockLoopX,inBlockLoopY,inBlockLoopZ, begin

     maskBool=$mainArrGPU[x,y,z]
     @processMaskData( maskBool) 
        
        #we add to source shmem also becouse 

    end  )#iterDataBlock
end) #quote              
end #loadMainValues
                

"""
now in case we  want later to establish source of the data - would like to find the true distances  not taking the assumption of isometric voxels
we need to store now data from what direction given voxel was activated what will later gratly simplify the task of finding the true distance 
we will record first found true voxel from each of six directions 
                 top 6 
                bottom 5  
                left 2
                right 1 
                anterior 3
                posterior 4
"""
function getDir(sourceShmem)
    if( @inbounds sourceShmem[xpos,ypos,zpos-1]) return 6  end  #up
    if( @inbounds  sourceShmem[xpos,ypos,zpos+1]) return 5  end #down

    if( @inbounds  sourceShmem[xpos-1,ypos,zpos]) return 2  end #left
    if( @inbounds   sourceShmem[xpos+1,ypos,zpos]) return 1  end #right

    if(  @inbounds  sourceShmem[xpos,ypos+1,zpos]) return 3  end #front
    if( @inbounds  sourceShmem[xpos,ypos-1,zpos]) return 4  end #back

end#getDir


macro executeDataIterWithPadding(isGoldPass,isToBeAnalyzedMain)
    return esc(quote
  #some data cleaning
#   locArr::UInt32 = UInt32(0)
#   # locFloat::Float32 = Float32(0.0)
#   isMaskFull::Bool= true
#   isMaskOkForProcessing::Bool = true
#   offset = 1
  ############## upload data
  @loadMainValues()                                       
  sync_threads()
  ########## check data aprat from padding
  #can be skipped if we have the block with already all results analyzed 
  if($isToBeAnalyzedMain[1])
      @validateData() 
  end                  
  #processing padding
  @processPadding()
  #now in case to establish is the block full we need to reduce the isMaskFull information
  @establishIsFull()
end)
end#executeDataIterWithPadding



"""
Iteration will start only if the associated  isToBeValidated entry in isToBevalidated data is true  (which we got from metadata and indicates is there anything of our intrest in validating given padding ...)

We should also supply loopX and loopY constants that are constant kernel wide  and can be precalculated 
maxXdim, maxYdim - provides maximal dimensions in x and y direction off padding plane (not of the whole image)
provides iteration over padding - we have 3 diffrent planes to analyze - and third dimensions will be rigidly set as constant and equal either to 1 or max of this simension
we also need supplied direction from which the dilatation was done (dir)           top 6          bottom 5     left 2       right 1      anterior 3      posterior 4
as tis is just basis that will be specialized for each padding we need also some expressions
    a,b.c - variables used to  getting value  from the padding and reurning true or false, it will operate using calculated x and y  (so we need to insert x symbol y symbol and constant number as a,b,c in coreect order) in diffrent psitions depending on the plane
    dataBdim - dimensionality of a data block 
//markNexBlockAsToBeActivated - whole expression that using given xMeta,yMeta,zMeta and the position of padding given we are in range will mark block as toBeActivated
    setMainArrToTrue - sets given spot in the main array to true - based on meta data and calculated inside loop x,y position
x,y offset and add probably can be left as defaoult
resShmem - shared memoy 3 dimensional boolean array
isAnyPositive - shared memory value indicating is anything was evaluated as true in the padding as true 
xMetaChange,yMetaChange,zMetaChange - indicates how the meata coordinates (coordinates of metadata block of intrest will change)
isToBeValidated - indicates weather we should validate data from dilatation or just write the dilatation to global memory
mainArr - main array which we modify during dilatations
refArr - array we will check weather dilatation had covered any new intresting voxel
resList - list with result
dir - direction from which we performed dilatation
queueNumber - what fp or fn queue we are intrested in modyfing now 
,xMeta,yMeta,zMeta - metadata x y z coordinates
"""
macro paddingIter(loopX,loopY,maxXdim, maxYdim,a,b,c , xMetaChange,yMetaChange,zMetaChange, mainArr, dir,queueNumber,xMeta,yMeta,zMeta)

    mainExp = generalizedItermultiDim(
    arrDims=:()
    ,loopXdim=loopXMeta 
    ,loopYdim=loopYMeta
#     ,additionalActionBeforeY= :( yMeta= rem(yzSpot,$metaDataDims[2]) ; zMeta= fld(yzSpot,$metaDataDims[2]) )
    ,additionalActionBeforeX= quote
            value = resShmem
        end#quote
       ,isFullBoundaryCheckX =true
   , isFullBoundaryCheckY=true
#   , isFullBoundaryCheckZ=true
#     ,nobundaryCheckX=true
#     , nobundaryCheckY=true
#     , nobundaryCheckZ =true
    ,yCheck = :(y <=$maxYdim)
    ,xCheck = :(x <=$maxXdim )
    # ,xAdd= :(threadIdxX()-1)# to keep all 0 based
    ,is3d = false
    , ex = esc(quote
            if(resShmem[$a,$b,$c])
                @inbounds resShmem[dir,1,1]=true# indicating that we have sth positive in this padding we are using a corner of the result shmem that will not be used in dilatation steps
                #below we do actual dilatation
                if($xMeta+$xMetaChange>0 && $xMeta+$xMetaChange<=metaDataDims[1]  && $yMeta+$yMetaChange>0 && $yMeta+$yMetaChange<=metaDataDims[2] && $zMeta+$zMetaChange>0 && $zMeta+$zMetaChange<=metaDataDims[3]  )
                    @inbounds mainArr[($xMeta-1)*$dataBdim[1]+$a,($yMeta-1)*$dataBdim[2]+$b,($zMeta-1)*$dataBdim[3]+$c]=true
                    if(isToBeValidated)
                        #if we have true in reference array in analyzed spot
                        if(refArr[($xMeta-1)*$dataBdim[1]+$a,($yMeta-1)*$dataBdim[2]+$b,($zMeta-1)*$dataBdim[3]+$c])
                            #adding the result to the result list at correct spot - using metadata taken from metadata
                            addResult($xMeta+$xMetaChange,$yMeta+$yMetaChange,zMeta+$zMetaChange, $resList,($xMeta-1)*$dataBdim[1]+$a,($yMeta-1)*$dataBdim[2]+$b, ($zMeta-1)*$dataBdim[3]+$c, $dir, $queueNumber,metaDataDims ,$isGold    )
                        end
                    end
                end
            end
            end))  
    return esc(:( $mainExp))
end
   

"""
invoked before kernel execution in order to set number of needed loop iterations
dataBdim - dimensions of the data block 
threadsXdim  - x dimension of the thread block
threadsYdim  - y dimension of the thread block
return tuple with numbers indicating how many iterations are needed in the loops of the kernel
"""
function calculateLoopsIter(dataBdim,threadsXdim,threadsYdim)
    loopAXFixed= cld(dataBdim[2], threadsXdim)
    loopBXfixed= cld(dataBdim[3], threadsYdim)
            
    loopAYFixed= cld(dataBdim[1], threadsXdim)
    loopBYfixed= cld(dataBdim[3], threadsYdim)
            
    loopAZFixed= cld(dataBdim[1], threadsXdim)
    loopBZfixed= cld(dataBdim[2], threadsYdim)

    loopdataDimMainX = cld(dataBdim[1], threadsXdim)
    loopdataDimMainY = cld(dataBdim[2], threadsYdim)
    loopdataDimMainZ =dataBdim[2]

return (loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ) 

end    


"""
executes paddingIter over all paddings 
"""
macro processPadding(isGold,xMeta,yMeta,zMeta)
    return esc(quote

    @checkIsToBeActivated should be invoked once
        #process left padding
        @paddingIter(loopAXFixed,loopBXfixed,dataBdim[2], dataBdim[3],1,:(x),:(y) , -1,0,0,  mainArr,1, 4-$isGold,$xMeta,$yMeta,$zMeta)
        #process rigth padding
        @paddingIter(loopAXFixed,loopBXfixed,dataBdim[2], dataBdim[3], dataBdim[1],:(x),:(y) , 1,0,0,  mainArr,2, 2-$isGold,$xMeta,$yMeta,$zMeta)
        #process posterior padding
        @paddingIter(loopAYFixed,loopBYfixed,dataBdim[1], dataBdim[3], :(x),1,:(y) , 0,-1,0,  mainArr,3, 8-$isGold,$xMeta,$yMeta,$zMeta)
        #process anterior padding
        @paddingIter(loopAYFixed,loopBYfixed,dataBdim[1], dataBdim[3], :(x),dataBdim[2],:(y) , 0,1,0,  mainArr,4, 6-$isGold,$xMeta,$yMeta,$zMeta)
        #process top padding
        @paddingIter(loopAZFixed,loopBZfixed,dataBdim[1], dataBdim[2], :(x),:(y),1 ,0,0,-1,  mainArr,5, 12-$isGold,$xMeta,$yMeta,$zMeta)
        #process bottom padding
        @paddingIter(loopAZFixed,loopBZfixed,dataBdim[1], dataBdim[2], :(x),:(y),dataBdim[3] , 0,0,1, mainArr,6, 10-$isGold,$xMeta,$yMeta,$zMeta)
        #checking res  shmem (we used part that is unused in  dilatation step) 
        sync_threads()
        @ifXY 1 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[1,1,1] ,-1,0,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 2 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[2,1,1] ,1,0,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 3 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[3,1,1] ,0,-1,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 4 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[4,1,1] ,0,1,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 5 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[5,1,1] ,0,0,-1,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 6 1 setNextBlockAsIsToBeActivated(@inbounds resShmem[6,1,1] , 0,0,1,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        sync_threads()

    end)

end#processPadding
           
"""
In case we have any true in padding we need to set the next block as to be activated 
yet we need also to test wheather next block in this direction actually exists so we check metadata dimensions
metaData - multidim array with metadata about data blocks
isToBeActivated - boolean taken from res shmem indicating weather there was any  true in related direction
xMeta,yMeta,zMeta - current metadata spot 
isGold - indicating wheather we are in gold or other pass
xMetaChange,yMetaChange,zMetaChange - points in which direction we should go in analyzis of metadata - how to change current metaData 
metaDataDims - dimensions of metadata

"""
function setNextBlockAsIsToBeActivated(isToBeActivated::Bool,xMetaChange,yMetaChange,zMetaChange,xMeta,yMeta,zMeta,isGold,  metaData, metaDataDims)
   if(isToBeActivated && xMeta+xMetaChange<=metaDataDims[1]  && yMeta+yMetaChange>0 && yMeta+yMetaChange<=metaDataDims[2] && zMeta+zMetaChange>0 && zMeta+zMetaChange<=metaDataDims[3]) 
    metaData[xMeta+xMetaChange,yMeta+yMetaChange,zMeta+zMetaChange,getIsToBeActivatedInSegmNumb()-isGold  ]=1 
    end
end



end#ProcessMainDataVerB





# """
# we are processing padding 
# """
# macro processPadding()
#     return esc(quote
#     #so here we utilize iter3 with 1 dim fixed 
#     @unroll for  dim in 1:3, numb in [1,34]              
#         @iter3dFixed dim numb if( isPaddingToBeAnalyzed(resShmem,dim,numb ))
#                 if(val)#if value in padding associated with this spot is true
#                     # setting value in global memory
#                     @inbounds  analyzedArr[x,y,z]= true
#                     # if we are here we have some voxel that was false in a primary mask and is becoming now true - if it is additionaly true in reference we need to add it to result
#                     resShmem[1,1,1]=true
#                     if(@inbounds referenceArray[x,y,z])
#                         appendResultPadding(metaData, linIndex, x,y,z,iterationnumber, dim,numb)
#                 end#if
#                 #we need to check is next block in given direction exists
#                 if(isNextBlockExists(metaData,dim, numb ,linIter, isPassGold, maxX,maxY,maxZ))
#                     if(resShmem[1,1,1])
#                         @ifXY 1 1 setAsToBeActivated(metaData,linIndex,isPassGold)
#                     end    
#                 end # if isNextBlockExists       
#             end # if isPaddingToBeAnalyzed   
#         end#iter3dFixed       
#     end#for
# end)
# end



